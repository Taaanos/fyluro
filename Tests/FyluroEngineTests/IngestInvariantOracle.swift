import CommonCrypto
import Darwin
import Foundation
import FyluroCore
import XCTest
@testable import FyluroEngine

/// Filesystem snapshot captured without following symbolic links.
struct TreeSnapshot {
    struct Entry: Equatable {
        enum Kind: Equatable {
            case file(size: Int64, sha256: String?, readable: Bool)
            case symlink(target: String)
            case directory
        }

        let relativePath: String
        let kind: Kind
        let modificationDateEpoch: TimeInterval
        let posixMode: UInt16
    }

    let rootPath: String
    let entries: [String: Entry]

    var files: [String: Entry] {
        entries.filter {
            if case .file = $0.value.kind { return true }
            return false
        }
    }

    static func capture(rootURL: URL) throws -> TreeSnapshot {
        let rootPath = rootURL.resolvingSymlinksInPath().path
        var entries: [String: Entry] = [:]
        if FileManager.default.fileExists(atPath: rootPath) {
            try walk(directoryPath: rootPath, rootPath: rootPath, into: &entries)
        }
        return TreeSnapshot(rootPath: rootPath, entries: entries)
    }

    private static func walk(
        directoryPath: String,
        rootPath: String,
        into entries: inout [String: Entry]
    ) throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            return
        }

        for name in names.sorted() {
            let fullPath = (directoryPath as NSString).appendingPathComponent(name)
            let relativePath = relative(fullPath, under: rootPath)

            var st = stat()
            guard lstat(fullPath, &st) == 0 else {
                continue
            }

            let fileType = st.st_mode & S_IFMT
            let mode = UInt16(st.st_mode & 0o7777)
            let mtime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0

            if fileType == S_IFLNK {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: fullPath)) ?? ""
                entries[relativePath] = Entry(
                    relativePath: relativePath,
                    kind: .symlink(target: target),
                    modificationDateEpoch: mtime,
                    posixMode: mode
                )
            } else if fileType == S_IFDIR {
                entries[relativePath] = Entry(
                    relativePath: relativePath,
                    kind: .directory,
                    modificationDateEpoch: mtime,
                    posixMode: mode
                )
                try walk(directoryPath: fullPath, rootPath: rootPath, into: &entries)
            } else if fileType == S_IFREG {
                let readable = access(fullPath, R_OK) == 0
                let hash = readable ? (try? sha256OfFile(atPath: fullPath)) : nil
                entries[relativePath] = Entry(
                    relativePath: relativePath,
                    kind: .file(size: Int64(st.st_size), sha256: hash, readable: readable),
                    modificationDateEpoch: mtime,
                    posixMode: mode
                )
            }
        }
    }

    static func relative(_ fullPath: String, under rootPath: String) -> String {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if fullPath.hasPrefix(prefix) {
            return String(fullPath.dropFirst(prefix.count))
        }
        return fullPath
    }

    static func sha256OfFile(atPath path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false))
        return sha256Hex(data)
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { rawBuffer in
            _ = CC_SHA256(rawBuffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct ParsedReceiptEvent {
    let sessionID: String
    let eventIndex: Int
    let timestamp: String
    let eventType: String
    let phase: String
    let data: [String: Any]
    let rawLine: String
}

/// Checks ROL-6 invariants I-1 through I-10 after any real `IngestSession` run.
enum IngestInvariantOracle {
    struct ExternalLibraryWrite {
        let relativePathUnderDest: String
        let sha256: String
    }

    struct RunContext {
        let seed: UInt64
        let runIndex: Int
        let sandboxRoot: URL
        let sourceRoot: URL
        let destinationRoot: URL
        let request: IngestRequest
        let faultInjection: IngestFaultInjection
        let result: IngestSessionResult
        let observedEvents: [IngestEvent]
        let sourceBefore: TreeSnapshot
        let sourceAfter: TreeSnapshot
        let sandboxBefore: TreeSnapshot
        let sandboxAfter: TreeSnapshot
        let destBefore: TreeSnapshot
        let destAfter: TreeSnapshot
        let externalLibraryWrites: [ExternalLibraryWrite]
        let expectedSymlinkTargetsOutsideSource: Set<String>
    }

    private static let filmModeRewritablePhotoExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "heic", "heif", "png",
    ]

    static func verify(
        _ ctx: RunContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tag = "[seed=\(ctx.seed) run=\(ctx.runIndex) session=\(ctx.request.sessionID)]"

        verifyI1SourceNeverChanged(ctx, tag: tag, file: file, line: line)
        let receipts = verifyI6ReceiptAlwaysWritten(ctx, tag: tag, file: file, line: line)
        verifyI2LibraryNeverOverwritten(ctx, tag: tag, file: file, line: line)
        verifyI3StagingAndFixedOrder(ctx, receipts: receipts, tag: tag, file: file, line: line)
        verifyI4PayloadPreservation(ctx, receipts: receipts, tag: tag, file: file, line: line)
        verifyI5VerificationMandatory(ctx, receipts: receipts, tag: tag, file: file, line: line)
        verifyI7FailedRunKeepsEvidence(ctx, receipts: receipts, tag: tag, file: file, line: line)
        verifyI8FilesystemDatesPreserved(ctx, receipts: receipts, tag: tag, file: file, line: line)
        verifyI9WritesOnlyToAllowedPlaces(ctx, tag: tag, file: file, line: line)
        verifyI10PathStrategyFixedAtRunStart(ctx, receipts: receipts, tag: tag, file: file, line: line)
    }

    // MARK: - I-1: The source card is never changed

    private static func verifyI1SourceNeverChanged(
        _ ctx: RunContext,
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(
            ctx.sourceBefore.entries,
            ctx.sourceAfter.entries,
            "\(tag) I-1 violated: source tree changed during ingest",
            file: file,
            line: line
        )
    }

    // MARK: - I-2: The library is never overwritten

    private static func verifyI2LibraryNeverOverwritten(
        _ ctx: RunContext,
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let beforeLibraryFiles = libraryFiles(from: ctx.destBefore)
        let afterLibraryFiles = libraryFiles(from: ctx.destAfter)

        for (relPath, beforeEntry) in beforeLibraryFiles {
            guard let afterEntry = afterLibraryFiles[relPath] else {
                XCTFail(
                    "\(tag) I-2 violated: pre-existing library file disappeared: \(relPath)",
                    file: file,
                    line: line
                )
                continue
            }
            XCTAssertEqual(
                beforeEntry.kind,
                afterEntry.kind,
                "\(tag) I-2 violated: pre-existing library file content changed: \(relPath)",
                file: file,
                line: line
            )
        }

        // Externally injected concurrent files (TOCTOU between plan and commit) must never be overwritten.
        for external in ctx.externalLibraryWrites {
            guard let afterEntry = afterLibraryFiles[external.relativePathUnderDest],
                  case let .file(_, afterHash, _) = afterEntry.kind else {
                XCTFail(
                    "\(tag) I-2 violated: concurrent library file missing after commit: \(external.relativePathUnderDest)",
                    file: file,
                    line: line
                )
                continue
            }
            XCTAssertEqual(
                afterHash,
                external.sha256,
                "\(tag) I-2 violated: concurrent library file overwritten: \(external.relativePathUnderDest)",
                file: file,
                line: line
            )
        }

        // Catch intra-run overwrites: distinct newly created library files must match committed count.
        let newlyCreated = newlyCommittedLibraryFiles(ctx)
        XCTAssertEqual(
            newlyCreated.count,
            ctx.result.counts.committed,
            "\(tag) I-2 violated: newly created library files (\(newlyCreated.count)) != committed count (\(ctx.result.counts.committed))",
            file: file,
            line: line
        )
    }

    // MARK: - I-3: Every file goes through staging, in a fixed order

    private static func verifyI3StagingAndFixedOrder(
        _ ctx: RunContext,
        receipts: [ParsedReceiptEvent],
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let phaseOrder: [IngestPhase: Int] = [
            .scan: 0,
            .plan: 1,
            .copy: 2,
            .verify: 3,
            .commit: 4,
            .finalize: 5,
        ]
        let observedPhases: [IngestPhase] = ctx.observedEvents.compactMap { event in
            if case let .phaseChanged(phase) = event { return phase }
            return nil
        }
        var lastRank = -1
        for phase in observedPhases {
            let rank = phaseOrder[phase] ?? -1
            XCTAssertGreaterThan(
                rank,
                lastRank,
                "\(tag) I-3 violated: out-of-order phase transition \(observedPhases)",
                file: file,
                line: line
            )
            lastRank = rank
        }

        // Every executed commit must follow an executed copy to staging and a passing verification.
        var copiedStagingPaths: Set<String> = []
        var verifiedStagingPaths: Set<String> = []

        for event in receipts {
            let executed = (event.data["executed"] as? Bool) ?? false
            guard executed else { continue }

            switch event.eventType {
            case "FILE_COPIED":
                if (event.data["status"] as? String) == "copied_to_staging",
                   let stagingPath = event.data["staging_path"] as? String {
                    copiedStagingPaths.insert(stagingPath)
                }
            case "FILE_VERIFIED":
                if (event.data["outcome"] as? String) == "verified",
                   (event.data["hash_match"] as? Bool) == true,
                   let stagingPath = event.data["staging_path"] as? String {
                    XCTAssertTrue(
                        copiedStagingPaths.contains(stagingPath),
                        "\(tag) I-3 violated: FILE_VERIFIED before FILE_COPIED for \(stagingPath)",
                        file: file,
                        line: line
                    )
                    verifiedStagingPaths.insert(stagingPath)
                }
            case "FILE_COMMITTED":
                if (event.data["status"] as? String) == "committed",
                   let stagingPath = event.data["staging_path"] as? String {
                    XCTAssertTrue(
                        verifiedStagingPaths.contains(stagingPath),
                        "\(tag) I-3 violated: FILE_COMMITTED without passing FILE_VERIFIED for \(stagingPath)",
                        file: file,
                        line: line
                    )
                }
            default:
                break
            }
        }

        // Copy or verify failures must halt before any file is committed.
        if ctx.result.failurePhase == .copy || ctx.result.failurePhase == .verify {
            XCTAssertEqual(
                ctx.result.counts.committed,
                0,
                "\(tag) I-3 violated: files were committed despite failure in \(ctx.result.failurePhase!.rawValue)",
                file: file,
                line: line
            )
            let newLibraryFiles = newlyCommittedLibraryFiles(ctx)
            XCTAssertTrue(
                newLibraryFiles.isEmpty,
                "\(tag) I-3 violated: destination gained library files after \(ctx.result.failurePhase!.rawValue) failure: \(newLibraryFiles.keys.sorted())",
                file: file,
                line: line
            )
        }

        XCTAssertLessThanOrEqual(
            ctx.result.counts.verified,
            ctx.result.counts.copied,
            "\(tag) I-3 violated: verified (\(ctx.result.counts.verified)) > copied (\(ctx.result.counts.copied))",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            ctx.result.counts.committed,
            ctx.result.counts.verified,
            "\(tag) I-3 violated: committed (\(ctx.result.counts.committed)) > verified (\(ctx.result.counts.verified))",
            file: file,
            line: line
        )

        // ROL-6 Section 9: hidden temporary copy files must never be left behind after copy ends or fails.
        let strayTemps = ctx.destAfter.files.keys.filter { path in
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix(".fyluro-") && name.hasSuffix(".tmp")
        }
        XCTAssertTrue(
            strayTemps.isEmpty,
            "\(tag) I-3/Section 9 violated: stray temporary staging files left behind: \(strayTemps.sorted())",
            file: file,
            line: line
        )
    }

    // MARK: - I-4: Embedded metadata and payload bytes preserved (Film Mode exception)

    private static func verifyI4PayloadPreservation(
        _ ctx: RunContext,
        receipts: [ParsedReceiptEvent],
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let committedEvents = executedCommittedEvents(from: receipts)
        let destRootPath = ctx.destinationRoot.resolvingSymlinksInPath().path
        let sourceRootPath = ctx.sourceRoot.resolvingSymlinksInPath().path

        for event in committedEvents {
            guard let sourcePath = event.data["source_path"] as? String,
                  let finalPath = event.data["final_path"] as? String else {
                XCTFail("\(tag) I-4: committed event missing source_path/final_path", file: file, line: line)
                continue
            }

            let sourceRel = TreeSnapshot.relative(URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path, under: sourceRootPath)
            let finalRel = TreeSnapshot.relative(URL(fileURLWithPath: finalPath).resolvingSymlinksInPath().path, under: destRootPath)

            guard let sourceEntry = ctx.sourceAfter.files[sourceRel],
                  case let .file(_, sourceHash?, true) = sourceEntry.kind else {
                XCTFail("\(tag) I-4: cannot locate source file \(sourceRel)", file: file, line: line)
                continue
            }
            guard let finalEntry = ctx.destAfter.files[finalRel],
                  case let .file(_, finalHash?, true) = finalEntry.kind else {
                XCTFail("\(tag) I-4: committed final file missing on disk: \(finalRel)", file: file, line: line)
                continue
            }

            let ext = (finalRel as NSString).pathExtension.lowercased()
            let filmModeMayRewrite = ctx.request.filmModeOverride != nil
                && filmModeRewritablePhotoExtensions.contains(ext)
                && !MediaSidecarSupport.transferExtensions.contains(ext)

            if !filmModeMayRewrite {
                XCTAssertEqual(
                    finalHash,
                    sourceHash,
                    "\(tag) I-4 violated: committed payload bytes differ from source for \(finalRel)",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - I-5: Verification cannot be turned off or skipped

    private static func verifyI5VerificationMandatory(
        _ ctx: RunContext,
        receipts: [ParsedReceiptEvent],
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let summaryData = receipts.last(where: { $0.eventType == "SUMMARY" })?.data
        let verifiedOK = (summaryData?["verified_ok"] as? Bool) ?? false

        if ctx.request.dryRun {
            XCTAssertFalse(verifiedOK, "\(tag) I-5 violated: dry run reported verified_ok=true", file: file, line: line)
            XCTAssertEqual(ctx.result.counts.copied, 0, "\(tag) I-5: dry run copied files", file: file, line: line)
            XCTAssertEqual(ctx.result.counts.verified, 0, "\(tag) I-5: dry run verified files", file: file, line: line)
            XCTAssertEqual(ctx.result.counts.committed, 0, "\(tag) I-5: dry run committed files", file: file, line: line)
            XCTAssertEqual(ctx.result.idempotency.classification, "dry_run_not_applicable", "\(tag) dry run classification", file: file, line: line)
            return
        }

        if ctx.result.finalStatus == "aborted" {
            XCTAssertFalse(verifiedOK, "\(tag) I-5 violated: aborted session reported verified_ok=true", file: file, line: line)
            XCTAssertEqual(ctx.result.idempotency.classification, "unknown_due_to_failure", "\(tag) aborted classification", file: file, line: line)
        } else {
            XCTAssertTrue(verifiedOK, "\(tag) I-5: completed non-dry run should report verified_ok=true", file: file, line: line)
            XCTAssertEqual(
                ctx.result.counts.copied,
                ctx.result.counts.verified,
                "\(tag) I-5 violated: copied (\(ctx.result.counts.copied)) != verified (\(ctx.result.counts.verified))",
                file: file,
                line: line
            )
        }

        if verifiedOK {
            for event in receipts where event.eventType == "FILE_VERIFIED" && (event.data["executed"] as? Bool) == true {
                XCTAssertEqual(event.data["outcome"] as? String, "verified", "\(tag) I-5 violated: failed verify in verified_ok session", file: file, line: line)
                XCTAssertEqual(event.data["hash_match"] as? Bool, true, "\(tag) I-5 violated: hash_match != true in verified_ok session", file: file, line: line)
            }
        }
    }

    // MARK: - I-6: The receipt is always written

    @discardableResult
    private static func verifyI6ReceiptAlwaysWritten(
        _ ctx: RunContext,
        tag: String,
        file: StaticString,
        line: UInt
    ) -> [ParsedReceiptEvent] {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ctx.result.receiptPath),
            "\(tag) I-6 violated: active receipt file missing at \(ctx.result.receiptPath)",
            file: file,
            line: line
        )

        let activeEvents = parseReceiptFile(atPath: ctx.result.receiptPath, tag: tag, file: file, line: line)
        let summaryEvent = activeEvents.last(where: { $0.eventType == "SUMMARY" })
        let finishedEvent = activeEvents.last(where: { $0.eventType == "SESSION_FINISHED" })

        XCTAssertNotNil(summaryEvent, "\(tag) I-6 violated: missing SUMMARY event in receipt", file: file, line: line)
        XCTAssertNotNil(finishedEvent, "\(tag) I-6 violated: missing SESSION_FINISHED event in receipt", file: file, line: line)

        // Collect all receipt sink paths recorded in SUMMARY so failover histories are verified end-to-end.
        var sinkPaths: [String] = []
        if let receiptPathsPayload = summaryEvent?.data["receipt_paths"] as? [[String: Any]] {
            for entry in receiptPathsPayload {
                if let path = entry["path"] as? String, !sinkPaths.contains(path) {
                    sinkPaths.append(path)
                }
            }
        }
        if !sinkPaths.contains(ctx.result.receiptPath) {
            sinkPaths.append(ctx.result.receiptPath)
        }

        var eventsByIndex: [Int: ParsedReceiptEvent] = [:]
        for path in sinkPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "\(tag) I-6 violated: listed receipt sink path missing: \(path)",
                file: file,
                line: line
            )
            let parsed = parseReceiptFile(atPath: path, tag: tag, file: file, line: line)
            for event in parsed {
                XCTAssertEqual(
                    event.sessionID,
                    ctx.request.sessionID,
                    "\(tag) I-6 violated: wrong session_id in receipt",
                    file: file,
                    line: line
                )
                if let existing = eventsByIndex[event.eventIndex] {
                    // Failover replays unflushed events; overlapping event indices must match identically.
                    XCTAssertEqual(
                        existing.rawLine,
                        event.rawLine,
                        "\(tag) I-6 violated: divergent event_index \(event.eventIndex) across failover sinks",
                        file: file,
                        line: line
                    )
                } else {
                    eventsByIndex[event.eventIndex] = event
                }
            }
        }

        let orderedIndices = eventsByIndex.keys.sorted()
        XCTAssertFalse(orderedIndices.isEmpty, "\(tag) I-6 violated: receipt contains zero events", file: file, line: line)
        if let maxIndex = orderedIndices.last {
            XCTAssertEqual(
                orderedIndices,
                Array(1...maxIndex),
                "\(tag) I-6 violated: non-contiguous event_index sequence across receipt sinks",
                file: file,
                line: line
            )
        }

        let allEvents = orderedIndices.compactMap { eventsByIndex[$0] }
        XCTAssertEqual(
            allEvents.first?.eventType,
            "SESSION_STARTED",
            "\(tag) I-6 violated: event 1 must be SESSION_STARTED",
            file: file,
            line: line
        )
        XCTAssertEqual(
            allEvents.last?.eventType,
            "SESSION_FINISHED",
            "\(tag) I-6 violated: last event must be SESSION_FINISHED",
            file: file,
            line: line
        )

        if let totals = summaryEvent?.data["totals_by_outcome"] as? [String: Any] {
            XCTAssertEqual(totals["copied"] as? Int, ctx.result.counts.copied, "\(tag) I-6: summary copied mismatch", file: file, line: line)
            XCTAssertEqual(totals["verified"] as? Int, ctx.result.counts.verified, "\(tag) I-6: summary verified mismatch", file: file, line: line)
            XCTAssertEqual(totals["committed"] as? Int, ctx.result.counts.committed, "\(tag) I-6: summary committed mismatch", file: file, line: line)
            XCTAssertEqual(totals["duplicate_not_copied"] as? Int, ctx.result.counts.duplicateNotCopied, "\(tag) I-6: summary duplicate mismatch", file: file, line: line)
            XCTAssertEqual(totals["conflicts_renamed"] as? Int, ctx.result.counts.conflictsRenamed, "\(tag) I-6: summary conflicts mismatch", file: file, line: line)
            XCTAssertEqual(totals["errors"] as? Int, ctx.result.counts.errors, "\(tag) I-6: summary errors mismatch", file: file, line: line)
        }

        if let failAt = ctx.faultInjection.receiptFailDestinationAppendAtEventIndex,
           let maxIndex = orderedIndices.last,
           maxIndex >= failAt {
            XCTAssertEqual(
                ctx.result.receiptSink,
                ReceiptSink.Kind.localFallback.rawValue,
                "\(tag) I-6 violated: expected receipt failover to \(ReceiptSink.Kind.localFallback.rawValue) at event \(failAt)",
                file: file,
                line: line
            )
            let transitions = summaryEvent?.data["receipt_sink_transitions"] as? [[String: Any]] ?? []
            XCTAssertFalse(transitions.isEmpty, "\(tag) I-6 violated: receipt failover missing sink transition record", file: file, line: line)
        } else {
            XCTAssertEqual(
                ctx.result.receiptSink,
                ReceiptSink.Kind.destination.rawValue,
                "\(tag) I-6: unexpected receipt failover without injected append error",
                file: file,
                line: line
            )
        }

        return allEvents
    }

    // MARK: - I-7: A failed run keeps its evidence

    private static func verifyI7FailedRunKeepsEvidence(
        _ ctx: RunContext,
        receipts: [ParsedReceiptEvent],
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let stagingSessionExists = FileManager.default.fileExists(atPath: ctx.result.stagingSessionPath)
        let anyFileReachedStaging = receipts.contains {
            $0.eventType == "FILE_COPIED"
                && ($0.data["executed"] as? Bool) == true
                && ($0.data["status"] as? String) == "copied_to_staging"
        }

        if ctx.request.dryRun {
            XCTAssertFalse(stagingSessionExists, "\(tag) I-7/dry-run violated: dry run created staging session folder", file: file, line: line)
            XCTAssertTrue(newlyCommittedLibraryFiles(ctx).isEmpty, "\(tag) I-7/dry-run violated: dry run wrote library files", file: file, line: line)
        } else if ctx.result.finalStatus == "aborted" {
            if anyFileReachedStaging {
                XCTAssertTrue(
                    stagingSessionExists,
                    "\(tag) I-7 violated: aborted run deleted its staging folder after staging files",
                    file: file,
                    line: line
                )
            }
        } else {
            let hadCleanupError = receipts.contains {
                $0.eventType == "ERROR" && $0.phase == "finalize" && (($0.data["staging_path"] as? String) != nil)
            }
            if !hadCleanupError {
                XCTAssertFalse(
                    stagingSessionExists,
                    "\(tag) I-7/Section 11 violated: completed non-dry run left its own staging session folder behind",
                    file: file,
                    line: line
                )
            }
        }

        // Prior sessions' staging folders must never be removed or altered by a later run.
        let priorStagingPrefix = "_ingest_staging/"
        let currentStagingPrefix = "_ingest_staging/\(ctx.request.sessionID)/"
        let currentStagingDir = "_ingest_staging/\(ctx.request.sessionID)"
        for (relPath, beforeEntry) in ctx.destBefore.entries {
            guard relPath.hasPrefix(priorStagingPrefix),
                  relPath != currentStagingDir,
                  !relPath.hasPrefix(currentStagingPrefix) else {
                continue
            }
            XCTAssertEqual(
                ctx.destAfter.entries[relPath]?.kind,
                beforeEntry.kind,
                "\(tag) I-7/I-9 violated: unrelated prior staging entry was modified or deleted: \(relPath)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - I-8: Filesystem dates are preserved

    private static func verifyI8FilesystemDatesPreserved(
        _ ctx: RunContext,
        receipts: [ParsedReceiptEvent],
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let committedEvents = executedCommittedEvents(from: receipts)
        let destRootPath = ctx.destinationRoot.resolvingSymlinksInPath().path
        let sourceRootPath = ctx.sourceRoot.resolvingSymlinksInPath().path

        for event in committedEvents {
            guard let sourcePath = event.data["source_path"] as? String,
                  let finalPath = event.data["final_path"] as? String else {
                continue
            }

            let sourceRel = TreeSnapshot.relative(URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path, under: sourceRootPath)
            let finalRel = TreeSnapshot.relative(URL(fileURLWithPath: finalPath).resolvingSymlinksInPath().path, under: destRootPath)

            guard let sourceEntry = ctx.sourceAfter.files[sourceRel],
                  let finalEntry = ctx.destAfter.files[finalRel] else {
                continue
            }

            let delta = abs(finalEntry.modificationDateEpoch - sourceEntry.modificationDateEpoch)
            XCTAssertLessThanOrEqual(
                delta,
                1.0,
                "\(tag) I-8 violated: committed mtime (\(finalEntry.modificationDateEpoch)) != source mtime (\(sourceEntry.modificationDateEpoch)) for \(finalRel)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - I-9: Writes go only to allowed places

    private static func verifyI9WritesOnlyToAllowedPlaces(
        _ ctx: RunContext,
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let sandboxRootPath = ctx.sandboxRoot.resolvingSymlinksInPath().path
        let destRootPath = ctx.destinationRoot.resolvingSymlinksInPath().path
        let destPrefix = TreeSnapshot.relative(destRootPath, under: sandboxRootPath) + "/"
        let allowedStagingDir = destPrefix + "_ingest_staging/\(ctx.request.sessionID)"
        let allowedReceiptPrefix = destPrefix + "_ingest_receipts/\(ctx.request.sessionID)."

        // Any newly created or modified entry in the sandbox must be inside dest/ and not another session's internal files.
        for (relPath, afterEntry) in ctx.sandboxAfter.entries {
            let beforeEntry = ctx.sandboxBefore.entries[relPath]
            if beforeEntry?.kind == afterEntry.kind {
                continue
            }

            XCTAssertTrue(
                relPath.hasPrefix(destPrefix),
                "\(tag) I-9 violated: write occurred outside destination root: \(relPath)",
                file: file,
                line: line
            )

            if relPath.hasPrefix(destPrefix + "_ingest_staging/") {
                XCTAssertTrue(
                    relPath == allowedStagingDir || relPath.hasPrefix(allowedStagingDir + "/"),
                    "\(tag) I-9 violated: write into another session's staging path: \(relPath)",
                    file: file,
                    line: line
                )
            }

            if relPath.hasPrefix(destPrefix + "_ingest_receipts/") {
                XCTAssertTrue(
                    relPath.hasPrefix(allowedReceiptPrefix),
                    "\(tag) I-9 violated: write into another session's receipt path: \(relPath)",
                    file: file,
                    line: line
                )
            }
        }

        // Only this session's staging folder (and an emptied _ingest_staging parent) may ever be deleted.
        for (relPath, _) in ctx.sandboxBefore.entries where ctx.sandboxAfter.entries[relPath] == nil {
            let isOwnStaging = relPath == allowedStagingDir
                || relPath.hasPrefix(allowedStagingDir + "/")
                || relPath == destPrefix + "_ingest_staging"
            XCTAssertTrue(
                isOwnStaging,
                "\(tag) I-9 violated: disallowed deletion outside session staging: \(relPath)",
                file: file,
                line: line
            )
        }

        // Symlink targets outside source must never be copied into destination.
        if !ctx.expectedSymlinkTargetsOutsideSource.isEmpty {
            let destHashes = Set(libraryFiles(from: ctx.destAfter).values.compactMap { entry -> String? in
                if case let .file(_, hash?, _) = entry.kind { return hash }
                return nil
            })
            for secretHash in ctx.expectedSymlinkTargetsOutsideSource {
                XCTAssertFalse(
                    destHashes.contains(secretHash),
                    "\(tag) I-9/Section 5 violated: out-of-source symlink target bytes appeared in destination",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - I-10: The path strategy is fixed at run start

    private static func verifyI10PathStrategyFixedAtRunStart(
        _ ctx: RunContext,
        receipts: [ParsedReceiptEvent],
        tag: String,
        file: StaticString,
        line: UInt
    ) {
        let expectedScheme = ctx.request.pathScheme.receiptPathSchemeString
        for eventType in ["SESSION_STARTED", "PLAN_COMPUTED", "SUMMARY", "SESSION_FINISHED"] {
            if let event = receipts.last(where: { $0.eventType == eventType }) {
                XCTAssertEqual(
                    event.data["path_scheme"] as? String,
                    expectedScheme,
                    "\(tag) I-10 violated: path_scheme mismatch in \(eventType)",
                    file: file,
                    line: line
                )
            }
        }

        if let started = receipts.first(where: { $0.eventType == "SESSION_STARTED" }) {
            XCTAssertEqual(
                started.data["hardware_verification"] as? Bool,
                ctx.request.hardwareVerification,
                "\(tag) I-10 violated: hardware_verification snapshot mismatch",
                file: file,
                line: line
            )
            XCTAssertEqual(
                started.data["camera_catalog_used"] as? Bool,
                ctx.request.useCameraCatalog,
                "\(tag) I-10 violated: camera_catalog_used snapshot mismatch",
                file: file,
                line: line
            )
            XCTAssertEqual(
                started.data["max_parallel_copies"] as? Int,
                ctx.request.maxParallelCopies,
                "\(tag) I-10 violated: max_parallel_copies snapshot mismatch",
                file: file,
                line: line
            )
        }

        // Verify every committed file path conforms to the snapshotted ImportPathScheme.
        let destRootPath = ctx.destinationRoot.resolvingSymlinksInPath().path
        for event in executedCommittedEvents(from: receipts) {
            guard let finalPath = event.data["final_path"] as? String else { continue }
            let relPath = TreeSnapshot.relative(URL(fileURLWithPath: finalPath).resolvingSymlinksInPath().path, under: destRootPath)
            XCTAssertTrue(
                matchesPathScheme(relativePath: relPath, scheme: ctx.request.pathScheme),
                "\(tag) I-10 violated: committed path '\(relPath)' does not match scheme '\(expectedScheme)'",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Helpers

    private static func libraryFiles(from snapshot: TreeSnapshot) -> [String: TreeSnapshot.Entry] {
        snapshot.files.filter { path, _ in
            !path.hasPrefix("_ingest_staging/") && !path.hasPrefix("_ingest_receipts/")
        }
    }

    private static func newlyCommittedLibraryFiles(_ ctx: RunContext) -> [String: TreeSnapshot.Entry] {
        let before = libraryFiles(from: ctx.destBefore)
        let after = libraryFiles(from: ctx.destAfter)
        let externalPaths = Set(ctx.externalLibraryWrites.map(\.relativePathUnderDest))
        return after.filter { path, _ in
            before[path] == nil && !externalPaths.contains(path)
        }
    }

    private static func executedCommittedEvents(from receipts: [ParsedReceiptEvent]) -> [ParsedReceiptEvent] {
        receipts.filter {
            $0.eventType == "FILE_COMMITTED"
                && ($0.data["executed"] as? Bool) == true
                && ($0.data["status"] as? String) == "committed"
        }
    }

    private static func parseReceiptFile(
        atPath path: String,
        tag: String,
        file: StaticString,
        line: UInt
    ) -> [ParsedReceiptEvent] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(tag) I-6: failed to read receipt at \(path)", file: file, line: line)
            return []
        }

        var parsed: [ParsedReceiptEvent] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(rawLine)
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineStr.utf8)) as? [String: Any] else {
                XCTFail("\(tag) I-6: invalid JSON line in receipt: \(lineStr)", file: file, line: line)
                continue
            }
            guard let sessionID = object["session_id"] as? String,
                  let eventIndex = object["event_index"] as? Int,
                  let timestamp = object["timestamp"] as? String,
                  let eventType = object["event_type"] as? String,
                  let phase = object["phase"] as? String,
                  let data = object["data"] as? [String: Any] else {
                XCTFail("\(tag) I-6: missing required receipt fields in line: \(lineStr)", file: file, line: line)
                continue
            }
            parsed.append(ParsedReceiptEvent(
                sessionID: sessionID,
                eventIndex: eventIndex,
                timestamp: timestamp,
                eventType: eventType,
                phase: phase,
                data: data,
                rawLine: lineStr
            ))
        }
        return parsed
    }

    private static func matchesPathScheme(relativePath: String, scheme: ImportPathScheme) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 3 else { return false }

        var cursor = 0
        if components[0] == "_unsorted" {
            cursor = 1
        } else {
            switch scheme.chronologicalLayout {
            case .yearYearMonthCompact:
                guard components.count > 2,
                      isDigits(components[0], length: 4),
                      isDigits(components[1], length: 6) else { return false }
                cursor = 2
            case .yearMonthNested:
                guard components.count > 2,
                      isDigits(components[0], length: 4),
                      isDigits(components[1], length: 2) else { return false }
                cursor = 2
            case .yearOnly:
                guard isDigits(components[0], length: 4) else { return false }
                cursor = 1
            }
        }

        // ROL-6 Section 4: standalone audio always lands at <chronological|_unsorted>/audio/<filename>.
        if cursor + 1 < components.count,
           components[cursor] == CameraLabeler.audioLabel,
           components.count == cursor + 2 {
            return true
        }

        if scheme.includeCameraFolder {
            guard cursor < components.count else { return false }
            let cameraFolder = components[cursor]
            guard !cameraFolder.isEmpty else { return false }
            cursor += 1
        }

        guard cursor < components.count else { return false }
        let mediaFolder = components[cursor].lowercased()
        guard mediaFolder == "photos" || mediaFolder == "videos" else { return false }
        cursor += 1

        if scheme.splitPhotoCompression && mediaFolder == "photos" {
            guard cursor < components.count else { return false }
            let bucket = components[cursor]
            guard bucket == "RAW" || bucket == "Non-RAW" else { return false }
            cursor += 1
        }

        return components.count == cursor + 1
    }

    private static func isDigits(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy(\.isNumber)
    }
}
