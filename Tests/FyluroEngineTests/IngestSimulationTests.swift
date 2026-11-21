import CoreGraphics
import Foundation
import FyluroCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FyluroEngine

/// Deterministic SplitMix64 generator so any failing seed replays identically.
private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % span)
    }

    mutating func nextBool(probabilityPercent: Int = 50) -> Bool {
        nextInt(in: 1...100) <= probabilityPercent
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[nextInt(in: 0...(items.count - 1))]
    }

    mutating func nextBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            bytes[index] = UInt8(truncatingIfNeeded: nextUInt64())
        }
        return Data(bytes)
    }
}

private struct NoopSleepAssertionManager: IdleSleepAssertionManaging {
    func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)? { nil }
}

private struct FixedMediumDetector: DestinationMediumDetecting {
    let medium: DestinationMediumType
    func detectMediumType(at destinationURL: URL) -> DestinationMediumType { medium }
}

private final class SimulationEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [IngestEvent] = []

    func record(_ event: IngestEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    var snapshot: [IngestEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

private final class SimulationMutationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var externalWrites: [IngestInvariantOracle.ExternalLibraryWrite] = []
    private var plannedTargets: [(sourcePath: String, finalPath: String)] = []
    private var cancelTriggered = false
    private var collisionTriggered = false
    private var copyStartedCount = 0
    private var verifiedCount = 0
    private var committedCount = 0

    func setPlannedTargets(_ targets: [(sourcePath: String, finalPath: String)]) {
        lock.lock(); defer { lock.unlock() }
        plannedTargets = targets
    }

    func firstPlannedTarget() -> (sourcePath: String, finalPath: String)? {
        lock.lock(); defer { lock.unlock() }
        return plannedTargets.first
    }

    func nextCopyStartedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        copyStartedCount += 1
        return copyStartedCount
    }

    func nextVerifiedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        verifiedCount += 1
        return verifiedCount
    }

    func nextCommittedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        committedCount += 1
        return committedCount
    }

    func claimCancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelTriggered { return false }
        cancelTriggered = true
        return true
    }

    func claimCollision() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if collisionTriggered { return false }
        collisionTriggered = true
        return true
    }

    func recordExternalWrite(_ write: IngestInvariantOracle.ExternalLibraryWrite) {
        lock.lock(); defer { lock.unlock() }
        externalWrites.append(write)
    }

    var recordedExternalWrites: [IngestInvariantOracle.ExternalLibraryWrite] {
        lock.lock(); defer { lock.unlock() }
        return externalWrites
    }
}

final class IngestSimulationTests: XCTestCase {
    private var tempRoot: URL!
    private var invocationTag: String!
    private var unreadablePathsToRestore: [String] = []
    private var fallbackReceiptPathsToClean: [String] = []

    override func setUpWithError() throws {
        invocationTag = String(UUID().uuidString.lowercased().prefix(8))
        let unique = "fyluro-dst-sim-\(invocationTag!)"
        let rawRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        // Resolve /var -> /private/var once so every snapshot path matches standardizedFileURL.
        tempRoot = rawRoot.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        for path in unreadablePathsToRestore {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        unreadablePathsToRestore.removeAll()

        for path in fallbackReceiptPathsToClean {
            try? FileManager.default.removeItem(atPath: path)
        }
        fallbackReceiptPathsToClean.removeAll()

        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Simulation Entry Points

    /// Runs a suite of seeded end-to-end simulations covering random cards, configs,
    /// faults, cancels, concurrent collisions, and multi-run recovery sequences.
    /// Set `FYLURO_SIM_SEED=<uint64>` to replay a single seed, or `FYLURO_SIM_SEEDS=<count>`
    /// to scale the suite size.
    func testSeededSimulationSuiteHoldsAllInvariants() throws {
        let env = ProcessInfo.processInfo.environment
        if let singleSeedStr = env["FYLURO_SIM_SEED"], let singleSeed = UInt64(singleSeedStr) {
            try runSeededScenario(seed: singleSeed, mode: .mixed)
            return
        }

        let count = Int(env["FYLURO_SIM_SEEDS"] ?? "") ?? 40
        for offset in 0..<count {
            let seed = UInt64(0xF110_0000) &+ UInt64(offset)
            try runSeededScenario(seed: seed, mode: .mixed)
        }
    }

    /// Runs a faulted session (copy/verify/commit failure or cancel), then recovers with
    /// a clean run on the same destination, then verifies a third run is an idempotent rerun.
    func testSeededMultiRunCrashRecoveryAndIdempotency() throws {
        for offset in 0..<20 {
            let seed = UInt64(0xF220_0000) &+ UInt64(offset)
            try runSeededScenario(seed: seed, mode: .faultRecoverRerun)
        }
    }

    /// Injects external library files between `plan` and `commit` (both duplicates and
    /// different-byte conflicts) and verifies I-2 (no overwrite) and all other invariants.
    func testSeededConcurrentDestinationCollisionsNeverOverwrite() throws {
        for offset in 0..<20 {
            let seed = UInt64(0xF330_0000) &+ UInt64(offset)
            try runSeededScenario(seed: seed, mode: .concurrentCollision)
        }
    }

    /// Combines destination receipt append failure (triggering local fallback failover)
    /// with copy/verify/commit failures and cancels.
    func testSeededCombinedFaultsWithReceiptFailover() throws {
        for offset in 0..<15 {
            let seed = UInt64(0xF440_0000) &+ UInt64(offset)
            try runSeededScenario(seed: seed, mode: .combinedReceiptFailover)
        }
    }

    /// Verifies overlap preflight (ROL-6 Section 11, I-1, I-9) rejects source==dest,
    /// dest inside source, and source inside dest with zero filesystem writes.
    func testOverlappingPathsRejectBeforeAnyWrite() throws {
        var rng = SeededRNG(seed: 0xF550_0001)
        let card = try generateCardAndDestination(seed: 0xF550_0001, rng: &rng)
        let nestedDest = card.sourceURL.appendingPathComponent("nested-dest", isDirectory: true)
        let nestedSource = card.destURL.appendingPathComponent("nested-source", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)

        let pairs: [(URL, URL)] = [
            (card.sourceURL, card.sourceURL),
            (card.sourceURL, nestedDest),
            (nestedSource, card.destURL),
        ]

        for (source, dest) in pairs {
            let before = try TreeSnapshot.capture(rootURL: card.sandboxURL)
            let request = IngestRequest(
                sourceURL: source,
                destinationURL: dest,
                sourceResolution: "explicit",
                destinationResolution: "explicit",
                pathScheme: .default,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: 1,
                jsonSummaryRequested: false,
                detectTimeoutSeconds: 60,
                pickSource: false,
                pickDestination: false,
                useCameraCatalog: false
            )
            let session = IngestSession(
                request: request,
                logger: NoopIngestLogger(),
                faultInjection: .none,
                destinationMediumDetector: FixedMediumDetector(medium: .solidState)
            )
            session.idleSleepAssertionManager = NoopSleepAssertionManager()

            XCTAssertThrowsError(try session.run()) { error in
                guard case IngestPreflightError.overlappingPaths = error else {
                    XCTFail("Expected IngestPreflightError.overlappingPaths, got \(error)")
                    return
                }
            }

            let after = try TreeSnapshot.capture(rootURL: card.sandboxURL)
            XCTAssertEqual(before.entries, after.entries, "I-1/I-9 violated: overlap preflight wrote to disk")
        }
    }

    // MARK: - Scenario Engine

    private enum ScenarioMode {
        case mixed
        case faultRecoverRerun
        case concurrentCollision
        case combinedReceiptFailover
    }

    private enum CancelTrigger {
        case none
        case beforeRun
        case onPlanPhase
        case onCopyStarted(nth: Int)
        case onVerifyPhase
        case onVerified(nth: Int)
        case onCommitPhase
        case onCommitted(nth: Int)
    }

    private enum ConcurrentRaceMode {
        case none
        case conflictAtFirstPlannedFinal
        case duplicateAtFirstPlannedFinal
    }

    private struct GeneratedCard {
        let sourceURL: URL
        let destURL: URL
        let sandboxURL: URL
        let readableFileCount: Int
        let symlinkSecretHashes: Set<String>
    }

    private func runSeededScenario(seed: UInt64, mode: ScenarioMode) throws {
        var rng = SeededRNG(seed: seed)
        let card = try generateCardAndDestination(seed: seed, rng: &rng)
        let baseScheme = randomPathScheme(rng: &rng)
        let medium = rng.pick([DestinationMediumType.rotationalHDD, .solidState, .unknown])

        switch mode {
        case .mixed:
            let runCount = rng.nextInt(in: 1...3)
            for runIndex in 1...runCount {
                let useSameScheme = rng.nextBool(probabilityPercent: 75)
                let scheme = useSameScheme ? baseScheme : randomPathScheme(rng: &rng)
                let dryRun = rng.nextBool(probabilityPercent: 18)
                let filmMode: FilmModeOverride? = (!dryRun && rng.nextBool(probabilityPercent: 15))
                    ? randomFilmMode(rng: &rng)
                    : nil
                let fault = dryRun ? IngestFaultInjection.none : randomFaultInjection(rng: &rng, maxFiles: max(1, card.readableFileCount))
                let cancelTrigger: CancelTrigger = dryRun ? .none : randomCancelTrigger(rng: &rng, maxFiles: max(1, card.readableFileCount))
                let raceMode: ConcurrentRaceMode = dryRun ? .none : randomRaceMode(rng: &rng)

                _ = try executeAndVerifyRun(
                    seed: seed,
                    runIndex: runIndex,
                    card: card,
                    scheme: scheme,
                    medium: medium,
                    dryRun: dryRun,
                    writePDF: false,
                    maxParallelCopies: rng.pick([1, 2]),
                    hardwareVerification: rng.nextBool(probabilityPercent: 80),
                    filmModeOverride: filmMode,
                    faultInjection: fault,
                    cancelTrigger: cancelTrigger,
                    raceMode: raceMode,
                    rng: &rng
                )
            }

        case .faultRecoverRerun:
            // Run 1: guaranteed fault or cancel.
            let faultKind = rng.nextInt(in: 0...4)
            var fault = IngestFaultInjection.none
            var cancelTrigger = CancelTrigger.none
            switch faultKind {
            case 0:
                fault.failCopyOnNthFile = rng.nextInt(in: 1...max(1, card.readableFileCount))
            case 1:
                fault.corruptStagingBeforeVerify = true
            case 2:
                fault.failCommitOnNthFile = rng.nextInt(in: 1...max(1, card.readableFileCount))
            case 3:
                fault.forceInsufficientDiskSpace = true
            default:
                cancelTrigger = rng.pick([
                    .onCopyStarted(nth: 1),
                    .onVerifyPhase,
                    .onCommitPhase,
                    .onCommitted(nth: 1),
                ])
            }
            let run1 = try executeAndVerifyRun(
                seed: seed,
                runIndex: 1,
                card: card,
                scheme: baseScheme,
                medium: medium,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: rng.pick([1, 2]),
                hardwareVerification: true,
                filmModeOverride: nil,
                faultInjection: fault,
                cancelTrigger: cancelTrigger,
                raceMode: .none,
                rng: &rng
            )
            if card.readableFileCount > 0 {
                XCTAssertEqual(run1.finalStatus, "aborted", "[seed=\(seed)] run 1 expected aborted")
            }

            // Run 2: clean recovery run on the same destination.
            let run2 = try executeAndVerifyRun(
                seed: seed,
                runIndex: 2,
                card: card,
                scheme: baseScheme,
                medium: medium,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: rng.pick([1, 2]),
                hardwareVerification: true,
                filmModeOverride: nil,
                faultInjection: .none,
                cancelTrigger: .none,
                raceMode: .none,
                rng: &rng
            )
            XCTAssertEqual(run2.finalStatus, "completed", "[seed=\(seed)] recovery run 2 expected completed")

            // Run 3: idempotent rerun on the same destination.
            let run3 = try executeAndVerifyRun(
                seed: seed,
                runIndex: 3,
                card: card,
                scheme: baseScheme,
                medium: medium,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: 1,
                hardwareVerification: true,
                filmModeOverride: nil,
                faultInjection: .none,
                cancelTrigger: .none,
                raceMode: .none,
                rng: &rng
            )
            XCTAssertEqual(run3.finalStatus, "completed", "[seed=\(seed)] rerun 3 expected completed")
            XCTAssertEqual(run3.counts.committed, 0, "[seed=\(seed)] rerun 3 committed unexpected new files")
            if card.readableFileCount > 0 {
                XCTAssertEqual(
                    run3.idempotency.classification,
                    "idempotent_rerun",
                    "[seed=\(seed)] rerun 3 expected idempotent_rerun"
                )
            }

        case .concurrentCollision:
            let race: ConcurrentRaceMode = rng.nextBool() ? .conflictAtFirstPlannedFinal : .duplicateAtFirstPlannedFinal
            let result = try executeAndVerifyRun(
                seed: seed,
                runIndex: 1,
                card: card,
                scheme: baseScheme,
                medium: medium,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: rng.pick([1, 2]),
                hardwareVerification: true,
                filmModeOverride: nil,
                faultInjection: .none,
                cancelTrigger: .none,
                raceMode: race,
                rng: &rng
            )
            XCTAssertEqual(result.finalStatus, "completed", "[seed=\(seed)] concurrent race run expected completed")

            // Second pass after a race must stay safe and never overwrite.
            _ = try executeAndVerifyRun(
                seed: seed,
                runIndex: 2,
                card: card,
                scheme: baseScheme,
                medium: medium,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: 1,
                hardwareVerification: true,
                filmModeOverride: nil,
                faultInjection: .none,
                cancelTrigger: .none,
                raceMode: .conflictAtFirstPlannedFinal,
                rng: &rng
            )

        case .combinedReceiptFailover:
            var fault = IngestFaultInjection(
                receiptFailDestinationAppendAtEventIndex: rng.nextInt(in: 2...8)
            )
            var cancelTrigger = CancelTrigger.none
            switch rng.nextInt(in: 0...4) {
            case 0:
                fault.failCopyOnNthFile = rng.nextInt(in: 1...max(1, card.readableFileCount))
            case 1:
                fault.corruptStagingBeforeVerify = true
            case 2:
                fault.failCommitOnNthFile = rng.nextInt(in: 1...max(1, card.readableFileCount))
            case 3:
                cancelTrigger = rng.pick([.onPlanPhase, .onCopyStarted(nth: 1), .onCommitPhase])
            default:
                break
            }

            _ = try executeAndVerifyRun(
                seed: seed,
                runIndex: 1,
                card: card,
                scheme: baseScheme,
                medium: medium,
                dryRun: false,
                writePDF: false,
                maxParallelCopies: rng.pick([1, 2]),
                hardwareVerification: true,
                filmModeOverride: nil,
                faultInjection: fault,
                cancelTrigger: cancelTrigger,
                raceMode: .none,
                rng: &rng
            )
        }
    }

    @discardableResult
    private func executeAndVerifyRun(
        seed: UInt64,
        runIndex: Int,
        card: GeneratedCard,
        scheme: ImportPathScheme,
        medium: DestinationMediumType,
        dryRun: Bool,
        writePDF: Bool,
        maxParallelCopies: Int,
        hardwareVerification: Bool,
        filmModeOverride: FilmModeOverride?,
        faultInjection: IngestFaultInjection,
        cancelTrigger: CancelTrigger,
        raceMode: ConcurrentRaceMode,
        rng: inout SeededRNG
    ) throws -> IngestSessionResult {
        let sessionID = String(format: "sim-%@-%016llx-r%d-%04x", invocationTag, seed, runIndex, rng.nextInt(in: 0...0xFFFF))
        let request = IngestRequest(
            sessionID: sessionID,
            sourceURL: card.sourceURL,
            destinationURL: card.destURL,
            sourceResolution: "explicit",
            destinationResolution: "explicit",
            pathScheme: scheme,
            dryRun: dryRun,
            writePDF: writePDF,
            maxParallelCopies: maxParallelCopies,
            jsonSummaryRequested: false,
            detectTimeoutSeconds: 60,
            pickSource: false,
            pickDestination: false,
            filmModeOverride: filmModeOverride,
            // Avoid reading the developer's local Application Support catalog for determinism.
            useCameraCatalog: false,
            hardwareVerification: hardwareVerification
        )

        let sourceBefore = try TreeSnapshot.capture(rootURL: card.sourceURL)
        let sandboxBefore = try TreeSnapshot.capture(rootURL: card.sandboxURL)
        let destBefore = try TreeSnapshot.capture(rootURL: card.destURL)

        let session = IngestSession(
            request: request,
            logger: NoopIngestLogger(),
            faultInjection: faultInjection,
            destinationMediumDetector: FixedMediumDetector(medium: medium)
        )
        session.idleSleepAssertionManager = NoopSleepAssertionManager()

        let collector = SimulationEventCollector()
        let tracker = SimulationMutationTracker()
        let destRootPath = card.destURL.resolvingSymlinksInPath().path
        let conflictPayload = rng.nextBytes(count: 333)

        session.eventObserver = { [weak session] event in
            collector.record(event)

            // Capture planned final paths from the PLAN_COMPUTED receipt line so we can
            // inject a realistic TOCTOU collision right before commit starts.
            if case let .receiptLineAppended(line) = event,
               line.contains("\"event_type\":\"PLAN_COMPUTED\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let data = obj["data"] as? [String: Any],
               let files = data["files"] as? [[String: Any]] {
                let parsed: [(String, String)] = files.compactMap { entry in
                    guard (entry["outcome"] as? String) == "stage_and_commit",
                          let rel = entry["path"] as? String,
                          let finalPath = entry["final_path"] as? String else {
                        return nil
                    }
                    let srcPath = card.sourceURL.appendingPathComponent(rel, isDirectory: false).path
                    return (srcPath, finalPath)
                }
                tracker.setPlannedTargets(parsed)
            }

            // Inject concurrent external destination write right before commit runs.
            if raceMode != .none, case .phaseChanged(.commit) = event, tracker.claimCollision() {
                if let target = tracker.firstPlannedTarget() {
                    let targetURL = URL(fileURLWithPath: target.finalPath, isDirectory: false)
                    let dirURL = targetURL.deletingLastPathComponent()
                    let payload: Data
                    switch raceMode {
                    case .none:
                        payload = Data()
                    case .conflictAtFirstPlannedFinal:
                        payload = conflictPayload
                    case .duplicateAtFirstPlannedFinal:
                        payload = (try? Data(contentsOf: URL(fileURLWithPath: target.sourcePath))) ?? conflictPayload
                    }
                    if !FileManager.default.fileExists(atPath: targetURL.path),
                       (try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)) != nil,
                       FileManager.default.createFile(atPath: targetURL.path, contents: payload) {
                        let resolvedFinal = targetURL.resolvingSymlinksInPath().path
                        let relUnderDest = TreeSnapshot.relative(resolvedFinal, under: destRootPath)
                        tracker.recordExternalWrite(.init(
                            relativePathUnderDest: relUnderDest,
                            sha256: TreeSnapshot.sha256Hex(payload)
                        ))
                    }
                }
            }

            // Deterministic cancellation triggered at exact lifecycle boundaries.
            switch (cancelTrigger, event) {
            case (.onPlanPhase, .phaseChanged(.plan)):
                if tracker.claimCancel() { session?.cancel() }
            case let (.onCopyStarted(nth), .fileCopyStarted):
                if tracker.nextCopyStartedCount() == nth, tracker.claimCancel() { session?.cancel() }
            case (.onVerifyPhase, .phaseChanged(.verify)):
                if tracker.claimCancel() { session?.cancel() }
            case let (.onVerified(nth), .fileVerified):
                if tracker.nextVerifiedCount() == nth, tracker.claimCancel() { session?.cancel() }
            case (.onCommitPhase, .phaseChanged(.commit)):
                if tracker.claimCancel() { session?.cancel() }
            case let (.onCommitted(nth), .fileCommitted):
                if tracker.nextCommittedCount() == nth, tracker.claimCancel() { session?.cancel() }
            default:
                break
            }
        }

        if case .beforeRun = cancelTrigger {
            session.cancel()
        }

        let result = try session.run()

        // Track any local-fallback receipt created in NSTemporaryDirectory so tearDown removes it.
        if result.receiptSink == ReceiptSink.Kind.localFallback.rawValue {
            fallbackReceiptPathsToClean.append(result.receiptPath)
        }

        let sourceAfter = try TreeSnapshot.capture(rootURL: card.sourceURL)
        let sandboxAfter = try TreeSnapshot.capture(rootURL: card.sandboxURL)
        let destAfter = try TreeSnapshot.capture(rootURL: card.destURL)

        IngestInvariantOracle.verify(.init(
            seed: seed,
            runIndex: runIndex,
            sandboxRoot: card.sandboxURL,
            sourceRoot: card.sourceURL,
            destinationRoot: card.destURL,
            request: request,
            faultInjection: faultInjection,
            result: result,
            observedEvents: collector.snapshot,
            sourceBefore: sourceBefore,
            sourceAfter: sourceAfter,
            sandboxBefore: sandboxBefore,
            sandboxAfter: sandboxAfter,
            destBefore: destBefore,
            destAfter: destAfter,
            externalLibraryWrites: tracker.recordedExternalWrites,
            expectedSymlinkTargetsOutsideSource: card.symlinkSecretHashes
        ))

        return result
    }

    // MARK: - Seeded Generators

    private func generateCardAndDestination(seed: UInt64, rng: inout SeededRNG) throws -> GeneratedCard {
        let sandboxURL = tempRoot.appendingPathComponent(String(format: "seed-%016llx", seed), isDirectory: true)
        let sourceURL = sandboxURL.appendingPathComponent("source", isDirectory: true)
        let destURL = sandboxURL.appendingPathComponent("dest", isDirectory: true)
        let canaryURL = sandboxURL.appendingPathComponent("canary", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canaryURL, withIntermediateDirectories: true)

        // Canary file outside source: must remain untouched (I-9) and never be imported via symlink.
        let secretBytes = Data("CANARY-SECRET-\(seed)-".utf8) + rng.nextBytes(count: 128)
        let secretURL = canaryURL.appendingPathComponent("outside_secret.jpg", isDirectory: false)
        try secretBytes.write(to: secretURL)
        var secretHashes: Set<String> = [TreeSnapshot.sha256Hex(secretBytes)]

        let dcimA = sourceURL.appendingPathComponent("DCIM/100MEDIA", isDirectory: true)
        let dcimB = sourceURL.appendingPathComponent("DCIM/101MEDIA", isDirectory: true)
        let audioDir = sourceURL.appendingPathComponent("AUDIO", isDirectory: true)
        try FileManager.default.createDirectory(at: dcimA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dcimB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let cameras: [(make: String, model: String)] = [
            ("Canon", "EOS R5"),
            ("SONY", "ILCE-7M4"),
            ("FUJIFILM", "X-T5"),
            ("Apple", "iPhone 15 Pro"),
        ]

        let mediaCount = rng.nextInt(in: 2...7)
        var readableCount = 0
        var firstPhotoBytes: Data?
        var firstPhotoMtime: Date?

        for idx in 0..<mediaCount {
            let folder = rng.nextBool(probabilityPercent: 70) ? dcimA : dcimB
            let year = rng.nextInt(in: 2021...2026)
            let month = rng.nextInt(in: 1...12)
            let day = rng.nextInt(in: 1...28)
            let mtime = makeIntegerDate(year: year, month: month, day: day, hour: rng.nextInt(in: 0...23), minute: idx)
            let kind = rng.nextInt(in: 0...4)

            switch kind {
            case 0:
                // Valid JPEG with EXIF make/model/date.
                let cam = rng.pick(cameras)
                let filename = String(format: "IMG_%04d.JPG", idx)
                let fileURL = folder.appendingPathComponent(filename, isDirectory: false)
                let exifDate = String(format: "%04d:%02d:%02d 12:%02d:00", year, month, day, idx % 60)
                try writeTinyJPEG(
                    to: fileURL,
                    make: cam.make,
                    model: cam.model,
                    dateTimeOriginal: exifDate,
                    seedByte: UInt8((idx &* 37 &+ Int(seed & 0xFF)) & 0xFF)
                )
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
                readableCount += 1
                if firstPhotoBytes == nil {
                    firstPhotoBytes = try Data(contentsOf: fileURL)
                    firstPhotoMtime = mtime
                }
                // Optional photo sidecar (.XMP).
                if rng.nextBool(probabilityPercent: 35) {
                    let xmpURL = folder.appendingPathComponent(String(format: "IMG_%04d.XMP", idx), isDirectory: false)
                    let xmpBytes = Data("<x:xmpmeta><seed>\(seed)-\(idx)</seed></x:xmpmeta>".utf8)
                    try xmpBytes.write(to: xmpURL)
                    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: xmpURL.path)
                    readableCount += 1
                }

            case 1:
                // Valid PNG without EXIF (tests mtime fallback + unknown-camera).
                let filename = String(format: "SHOT_%04d.PNG", idx)
                let fileURL = folder.appendingPathComponent(filename, isDirectory: false)
                try writeTinyPNG(to: fileURL, seedByte: UInt8((idx &* 53) & 0xFF))
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
                readableCount += 1

            case 2:
                // Synthetic RAW photo (.DNG) to exercise RAW/Non-RAW split and Film Mode RAW skip.
                let filename = String(format: "RAW_%04d.DNG", idx)
                let fileURL = folder.appendingPathComponent(filename, isDirectory: false)
                try rng.nextBytes(count: rng.nextInt(in: 256...2048)).write(to: fileURL)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
                readableCount += 1

            case 3:
                // Video file (.MP4) with optional companion .SRT or DJI-style companion .WAV sidecar.
                let stem = String(format: "CLIP_%04d", idx)
                let videoURL = folder.appendingPathComponent("\(stem).MP4", isDirectory: false)
                try rng.nextBytes(count: rng.nextInt(in: 512...4096)).write(to: videoURL)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: videoURL.path)
                readableCount += 1
                if rng.nextBool(probabilityPercent: 40) {
                    let sidecarExt = rng.nextBool() ? "SRT" : "WAV"
                    let sidecarURL = folder.appendingPathComponent("\(stem).\(sidecarExt)", isDirectory: false)
                    try rng.nextBytes(count: 256).write(to: sidecarURL)
                    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: sidecarURL.path)
                    readableCount += 1
                }

            default:
                // Standalone audio file (.M4A or .WAV without matching video).
                let ext = rng.nextBool() ? "M4A" : "WAV"
                let audioURL = audioDir.appendingPathComponent(String(format: "VOICE_%04d.\(ext)", idx), isDirectory: false)
                try rng.nextBytes(count: rng.nextInt(in: 256...2048)).write(to: audioURL)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: audioURL.path)
                readableCount += 1
            }
        }

        // Occasionally add a same-batch filename collision across subdirectories.
        if rng.nextBool(probabilityPercent: 45), let sampleBytes = firstPhotoBytes, let sampleMtime = firstPhotoMtime {
            let duplicateOrConflict = rng.nextBool()
                ? sampleBytes
                : sampleBytes + Data([0xAA, 0xBB])
            let collidingURL = dcimB.appendingPathComponent("IMG_0000.jpg", isDirectory: false)
            if !FileManager.default.fileExists(atPath: collidingURL.path) {
                try duplicateOrConflict.write(to: collidingURL)
                try FileManager.default.setAttributes([.modificationDate: sampleMtime], ofItemAtPath: collidingURL.path)
                readableCount += 1
            }
        }

        // Occasionally add noise that must be skipped without error: hidden file, unknown ext, symlinks.
        if rng.nextBool(probabilityPercent: 60) {
            try Data("ignore".utf8).write(to: dcimA.appendingPathComponent(".hidden.jpg"))
            try Data("notes".utf8).write(to: dcimA.appendingPathComponent("README.TXT"))
        }
        if rng.nextBool(probabilityPercent: 50) {
            let fileLink = dcimA.appendingPathComponent("escape_link.jpg")
            try FileManager.default.createSymbolicLink(atPath: fileLink.path, withDestinationPath: secretURL.path)
            let dirLink = sourceURL.appendingPathComponent("escape_dir")
            try FileManager.default.createSymbolicLink(atPath: dirLink.path, withDestinationPath: canaryURL.path)
            secretHashes.insert(TreeSnapshot.sha256Hex(secretBytes))
        }

        // Occasionally add one unreadable source file (0o000): must record scan ERROR and continue.
        if rng.nextBool(probabilityPercent: 30) {
            let lockedURL = dcimA.appendingPathComponent("LOCKED_9999.JPG")
            try rng.nextBytes(count: 256).write(to: lockedURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedURL.path)
            unreadablePathsToRestore.append(lockedURL.path)
        }

        // Occasionally pre-seed destination with an unrelated existing library file and a prior aborted staging folder.
        if rng.nextBool(probabilityPercent: 65) {
            let preExistingDir = destURL.appendingPathComponent("2020/202001/legacy-camera/Photos", isDirectory: true)
            try FileManager.default.createDirectory(at: preExistingDir, withIntermediateDirectories: true)
            try rng.nextBytes(count: 512).write(to: preExistingDir.appendingPathComponent("LEGACY_0001.JPG"))
        }
        if rng.nextBool(probabilityPercent: 50) {
            let priorStaging = destURL
                .appendingPathComponent("_ingest_staging", isDirectory: true)
                .appendingPathComponent("prior-aborted-session", isDirectory: true)
            try FileManager.default.createDirectory(at: priorStaging, withIntermediateDirectories: true)
            try Data("prior-evidence".utf8).write(to: priorStaging.appendingPathComponent("PARTIAL.JPG"))
        }

        return GeneratedCard(
            sourceURL: sourceURL,
            destURL: destURL,
            sandboxURL: sandboxURL,
            readableFileCount: readableCount,
            symlinkSecretHashes: secretHashes
        )
    }

    private func randomPathScheme(rng: inout SeededRNG) -> ImportPathScheme {
        ImportPathScheme(
            chronologicalLayout: rng.pick(PathChronologicalLayout.allCases),
            includeCameraFolder: rng.nextBool(),
            splitPhotoCompression: rng.nextBool()
        )
    }

    private func randomFilmMode(rng: inout SeededRNG) -> FilmModeOverride {
        FilmModeOverride(
            year: rng.nextInt(in: 1985...2005),
            month: rng.nextInt(in: 1...12),
            camera: rng.pick(["Pentax K1000", "Nikon FM2", "Leica M6"]),
            filmStock: rng.pick([nil, "Kodak Portra 400", "Ilford HP5"]),
            iso: rng.pick([nil, 200, 400]),
            creator: nil,
            copyright: nil
        )
    }

    private func randomFaultInjection(rng: inout SeededRNG, maxFiles: Int) -> IngestFaultInjection {
        var fault = IngestFaultInjection.none
        let roll = rng.nextInt(in: 1...100)
        switch roll {
        case 1...40:
            break
        case 41...55:
            fault.failCopyOnNthFile = rng.nextInt(in: 1...maxFiles)
        case 56...68:
            fault.corruptStagingBeforeVerify = true
        case 69...82:
            fault.failCommitOnNthFile = rng.nextInt(in: 1...maxFiles)
        case 83...90:
            fault.forceInsufficientDiskSpace = true
        default:
            fault.receiptFailDestinationAppendAtEventIndex = rng.nextInt(in: 2...8)
        }

        // Occasionally combine receipt failover with another fault.
        if fault.receiptFailDestinationAppendAtEventIndex == nil, rng.nextBool(probabilityPercent: 15) {
            fault.receiptFailDestinationAppendAtEventIndex = rng.nextInt(in: 2...8)
        }
        return fault
    }

    private func randomCancelTrigger(rng: inout SeededRNG, maxFiles: Int) -> CancelTrigger {
        guard rng.nextBool(probabilityPercent: 20) else {
            return .none
        }
        return rng.pick([
            .beforeRun,
            .onPlanPhase,
            .onCopyStarted(nth: rng.nextInt(in: 1...maxFiles)),
            .onVerifyPhase,
            .onVerified(nth: rng.nextInt(in: 1...maxFiles)),
            .onCommitPhase,
            .onCommitted(nth: rng.nextInt(in: 1...maxFiles)),
        ])
    }

    private func randomRaceMode(rng: inout SeededRNG) -> ConcurrentRaceMode {
        let roll = rng.nextInt(in: 1...100)
        if roll <= 15 { return .conflictAtFirstPlannedFinal }
        if roll <= 25 { return .duplicateAtFirstPlannedFinal }
        return .none
    }

    private func makeIntegerDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let raw = comps.date ?? Date(timeIntervalSince1970: 1_700_000_000)
        return Date(timeIntervalSince1970: floor(raw.timeIntervalSince1970))
    }

    private func writeTinyJPEG(
        to url: URL,
        make: String,
        model: String,
        dateTimeOriginal: String,
        seedByte: UInt8
    ) throws {
        let image = try makeTinyCGImage(seedByte: seedByte)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "IngestSimulationTests", code: 1)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
            ],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "IngestSimulationTests", code: 2)
        }
    }

    private func writeTinyPNG(to url: URL, seedByte: UInt8) throws {
        let image = try makeTinyCGImage(seedByte: seedByte)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "IngestSimulationTests", code: 3)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "IngestSimulationTests", code: 4)
        }
    }

    private func makeTinyCGImage(seedByte: UInt8) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels: [UInt8] = [
            seedByte, seedByte ^ 0x55, seedByte ^ 0xAA, 255,
            seedByte ^ 0x11, seedByte, 128, 255,
            64, seedByte ^ 0x33, seedByte, 255,
            255, 128, seedByte, 255,
        ]
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: &pixels,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "IngestSimulationTests", code: 5)
        }
        return image
    }
}
