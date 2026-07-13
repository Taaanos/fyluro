import CryptoKit
import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeepLauncher
import RollKeepEngine

extension LauncherAppE2ETests {
    func runLauncherImport(
        source: URL,
        destination: URL,
        label: String,
        pathSchemeConfiguration: LauncherPathSchemeConfiguration = .default,
        environmentOverrides: [String: String] = [:]
    ) throws -> RunArtifacts {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let finder = StubLauncherFinderOpening()
        let memory = StubLauncherDestinationRemembering(initialPath: nil)
        let pathSchemeRemembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let pathSchemeStore = LauncherPathSchemeSettingsStore(pathSchemeRemembering: pathSchemeRemembering)
        pathSchemeStore.draftConfiguration = pathSchemeConfiguration
        pathSchemeStore.applyDraft()

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: memory,
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            pathSchemeSettingsStore: pathSchemeStore,
            sourceScanner: LauncherSharedSourceScanner(),
            finderOpening: finder,
            ingestRunnerFactory: { [environmentOverrides] request in
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in environmentOverrides {
                    environment[key] = value
                }
                return IngestSession.begin(
                    request: request,
                    logger: nil,
                    faultInjection: .fromEnvironment(environment)
                )
            }
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path
        XCTAssertTrue(waitUntil(timeout: 120) { viewModel.isImportReady }, "\(label): source scan never became import-ready")
        XCTAssertTrue(viewModel.canStart, "\(label): expected canStart before run")

        viewModel.startIngest()
        XCTAssertTrue(waitUntil(timeout: 240) {
            (viewModel.uiState == .success || viewModel.uiState == .failure) && !viewModel.isRunning
        }, "\(label): run did not finish")

        guard let receiptPath = resolveReceiptPath(viewModel: viewModel, destination: destination) else {
            XCTFail("\(label): missing receipt path")
            throw NSError(domain: "LauncherAppE2ETests", code: 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptPath), "\(label): receipt path does not exist")

        let events = try loadReceiptEvents(path: receiptPath)
        let summary = try summaryEventData(events: events)
        if viewModel.uiState == .success {
            try assertPDFSummaryArtifact(viewModel: viewModel, summaryData: summary, label: label)
        }

        return RunArtifacts(
            viewModel: viewModel,
            finder: finder,
            receiptPath: receiptPath,
            receiptEvents: events,
            summaryData: summary,
            destination: destination,
            source: source
        )
    }

    func resolveRepoRoot() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd
        }

        let testFile = URL(fileURLWithPath: #filePath)
        let inferred = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: inferred.appendingPathComponent("Package.swift").path) {
            return inferred
        }

        throw NSError(domain: "LauncherAppE2ETests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not resolve repo root"])
    }

    func makeTempDirectory(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let destination = root.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    func cloneAndAugmentSourceFixture(
        fixtureSource: URL,
        slimRelativePaths: [String],
        tempRoot: URL,
        scenarioName: String
    ) throws -> URL {
        let clone = tempRoot.appendingPathComponent("source-\(scenarioName)", isDirectory: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)

        for relativePath in slimRelativePaths {
            let sourcePath = fixtureSource.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourcePath.path) else {
                throw NSError(
                    domain: "LauncherAppE2ETests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Missing slim source fixture file: \(sourcePath.path)"]
                )
            }
            let destinationPath = clone.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: destinationPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourcePath, to: destinationPath)
        }

        let augmentedCaptureDate = Date(timeIntervalSince1970: 1_734_264_000) // 2024-12-15T12:00:00Z
        let augmentedFiles: [String: Data] = [
            "DCIM/E2E_RAW.CR3": Data("rollkeep-e2e-raw-photo-bytes\n".utf8),
            "DCIM/E2E_RAW.XMP": Data("<x:xmpmeta>raw-sidecar</x:xmpmeta>\n".utf8),
            "DCIM/E2E_STD.JPG": Data("rollkeep-e2e-standard-photo-bytes\n".utf8),
            "DCIM/E2E_STD.XMP": Data("<x:xmpmeta>standard-sidecar</x:xmpmeta>\n".utf8),
            "PRIVATE/E2E_VID.MP4": Data("rollkeep-e2e-video-bytes\n".utf8),
            "PRIVATE/E2E_VID.XML": Data("<Metadata><Clip>E2E_VID</Clip></Metadata>\n".utf8),
            "PRIVATE/E2E_KNOWN.MP4": Data("rollkeep-e2e-known-video-bytes\n".utf8),
            "PRIVATE/E2E_KNOWNM01.XML": Data(
                "<NonRealTimeMeta><CreationDate value=\"2024-12-15T12:00:00+00:00\"/><Device manufacturer=\"Sony\" modelName=\"ILCE-7CM2\" serialNo=\"4294967295\"/></NonRealTimeMeta>\n".utf8
            ),
            "DCIM/E2E_UNSORTED.JPG": Data("rollkeep-e2e-unsorted-photo-bytes\n".utf8),
            "PRIVATE/E2E_UNSORTED.MP4": Data("rollkeep-e2e-unsorted-video-bytes\n".utf8),
            "PRIVATE/E2E_UNSORTED.XML": Data("<Metadata><Clip>E2E_UNSORTED</Clip></Metadata>\n".utf8),
        ]

        for (relativePath, payload) in augmentedFiles {
            let path = clone.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: payload)
            try FileManager.default.setAttributes([.modificationDate: augmentedCaptureDate], ofItemAtPath: path.path)
        }

        return clone
    }

    func fileManifest(root: URL) throws -> [String: FileSnapshot] {
        let rootPath = root.path
        var manifest: [String: FileSnapshot] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let relativePath = item.path.replacingOccurrences(of: rootPath + "/", with: "")
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let size = attributes[.size] as? NSNumber ?? 0
            let mtime = attributes[.modificationDate] as? Date ?? Date.distantPast
            let hash = try sha256Hex(path: item)
            manifest[relativePath] = FileSnapshot(
                sha256: hash,
                size: size.uint64Value,
                mtimeNanoseconds: UInt64(mtime.timeIntervalSince1970 * 1_000_000_000)
            )
        }

        return manifest
    }

    func sha256Hex(path: URL) throws -> String {
        let data = try Data(contentsOf: path)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.02,
        _ condition: () -> Bool,
        _ message: String? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
        if let message {
            XCTFail(message)
        }
        return condition()
    }

    func resolveReceiptPath(viewModel: LauncherViewModel, destination: URL) -> String? {
        if !viewModel.receiptPath.isEmpty, FileManager.default.fileExists(atPath: viewModel.receiptPath) {
            return viewModel.receiptPath
        }

        if let discovered = activeReceiptPath(viewModel: viewModel, destination: destination) {
            return discovered
        }

        let outputLines = viewModel.outputText.split(separator: "\n").map(String.init)
        for line in outputLines.reversed() where line.hasPrefix("Receipt: ") {
            let parsed = String(line.dropFirst("Receipt: ".count))
            if FileManager.default.fileExists(atPath: parsed) {
                return parsed
            }
        }

        return nil
    }

    func inferRetainedStagingSessionPath(events: [[String: Any]], destination: URL) -> String? {
        let stagingRoot = destination
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .standardizedFileURL.path

        for event in events {
            let data = dictionaryValue(event["data"])
            let pathCandidates = [
                stringValue(data["staging_path"]),
                stringValue(data["path"]),
                stringValue(data["source_path"]),
            ]

            for candidate in pathCandidates where !candidate.isEmpty {
                let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
                guard normalized.hasPrefix(stagingRoot + "/") else {
                    continue
                }

                let suffix = normalized.dropFirst((stagingRoot + "/").count)
                guard let session = suffix.split(separator: "/").first else {
                    continue
                }
                return stagingRoot + "/" + session
            }
        }

        if let sessions = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: stagingRoot, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            return sessions
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.path)
                .sorted()
                .first
        }

        return nil
    }

    func activeReceiptPath(viewModel: LauncherViewModel, destination: URL) -> String? {
        let receiptsDirectory = destination.appendingPathComponent("_ingest_receipts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: receiptsDirectory.path) else {
            return nil
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: receiptsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let ndjsonEntries = entries.filter { $0.pathExtension == "ndjson" }
        let newest = ndjsonEntries.max { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }
        return newest?.path
    }

    func loadReceiptEvents(path: String) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var events: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            events.append(json)
        }
        return events
    }

    func summaryEventData(events: [[String: Any]]) throws -> [String: Any] {
        for event in events.reversed() {
            if stringValue(event["event_type"]) == "SUMMARY" {
                return dictionaryValue(event["data"])
            }
        }
        throw NSError(domain: "LauncherAppE2ETests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing SUMMARY event"])
    }
}
