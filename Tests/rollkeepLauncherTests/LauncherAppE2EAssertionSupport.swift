import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeepLauncher
import RollKeepEngine

extension LauncherAppE2ETests {
    func assertReceiptLifecycle(_ events: [[String: Any]], label: String) {
        let types = eventTypes(in: events)
        XCTAssertTrue(types.contains("SESSION_STARTED"), "\(label): missing SESSION_STARTED")
        XCTAssertTrue(types.contains("SESSION_FINISHED"), "\(label): missing SESSION_FINISHED")
    }

    func eventTypes(in events: [[String: Any]]) -> Set<String> {
        Set(events.compactMap { stringValue($0["event_type"]).isEmpty ? nil : stringValue($0["event_type"]) })
    }

    func assertErrorPhaseExists(_ events: [[String: Any]], expectedPhase: String, label: String) {
        let phases = events
            .filter { stringValue($0["event_type"]) == "ERROR" }
            .map { stringValue($0["phase"]) }
        XCTAssertTrue(phases.contains(expectedPhase), "\(label): expected ERROR phase \(expectedPhase), got \(phases)")
    }

    func assertCommittedFileMtimePreservation(summaryData: [String: Any], label: String) throws {
        let outcomes = arrayValue(summaryData["per_file_outcomes"])
        var compared = 0
        for outcomeValue in outcomes {
            guard let outcome = outcomeValue as? [String: Any] else {
                continue
            }
            guard stringValue(outcome["outcome"]) == "stage_and_commit",
                  boolValue(outcome["executed"]) == true else {
                continue
            }

            let sourcePath = stringValue(outcome["source_path"])
            let finalPath = stringValue(outcome["final_path"])
            guard !sourcePath.isEmpty, !finalPath.isEmpty else {
                continue
            }

            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourcePath)
            let finalAttributes = try FileManager.default.attributesOfItem(atPath: finalPath)
            guard let sourceMTime = sourceAttributes[.modificationDate] as? Date,
                  let finalMTime = finalAttributes[.modificationDate] as? Date else {
                continue
            }

            let delta = abs(sourceMTime.timeIntervalSince1970 - finalMTime.timeIntervalSince1970)
            XCTAssertLessThanOrEqual(delta, 1.0, "\(label): mtime delta too large (\(delta)) for \(finalPath)")
            compared += 1
        }

        XCTAssertGreaterThan(compared, 0, "\(label): expected at least one committed file mtime comparison")
    }

    func assertDestinationConstrainedWrites(summaryData: [String: Any], destination: URL, label: String) {
        let destinationPath = destination.standardizedFileURL.path
        let touched = dictionaryValue(summaryData["touched_paths"])

        let pathKeys = [
            "created_directories",
            "written_staging_files",
            "written_final_files",
            "written_receipt_files",
            "deleted_paths",
        ]

        for key in pathKeys {
            for path in stringArray(touched[key]) {
                XCTAssertTrue(
                    isPathAllowedByDestinationConstraint(path, destinationPath: destinationPath),
                    "\(label): touched path escaped destination constraints (\(key)): \(path)"
                )
            }
        }

        for moveValue in arrayValue(touched["move_operations"]) {
            guard let move = moveValue as? [String: Any] else {
                continue
            }
            let fromPath = stringValue(move["from"])
            let toPath = stringValue(move["to"])
            XCTAssertTrue(
                isPathAllowedByDestinationConstraint(fromPath, destinationPath: destinationPath),
                "\(label): move.from escaped destination constraints: \(fromPath)"
            )
            XCTAssertTrue(
                isPathAllowedByDestinationConstraint(toPath, destinationPath: destinationPath),
                "\(label): move.to escaped destination constraints: \(toPath)"
            )
        }
    }

    func isPathAllowedByDestinationConstraint(_ path: String, destinationPath: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        let normalizedPath = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
        let normalizedDestination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL.path
        if normalizedPath == normalizedDestination || normalizedPath.hasPrefix(normalizedDestination + "/") {
            return true
        }

        // Allow receipt failover writes in local temp only.
        if normalizedPath.contains("/rollkeep/_ingest_receipts/") {
            return true
        }

        return false
    }

    func assertFinalPathsConformToScheme(
        writtenFinalFiles: [String],
        destination: URL,
        scheme: LauncherPathSchemeConfiguration,
        label: String
    ) {
        let destinationPrefix = destination.standardizedFileURL.path + "/"
        for fullPath in writtenFinalFiles {
            XCTAssertTrue(fullPath.hasPrefix(destinationPrefix), "\(label): final path should stay in destination: \(fullPath)")
            let relativePath = String(fullPath.dropFirst(destinationPrefix.count))
            let components = relativePath.split(separator: "/").map(String.init)
            XCTAssertGreaterThanOrEqual(components.count, 3, "\(label): expected at least 3 path components in \(relativePath)")
            if components.isEmpty {
                continue
            }

            var index = 0
            if components[0] == "_unsorted" {
                index = 1
            } else {
                switch scheme.chronologicalLayout {
                case .yearYearMonthCompact:
                    XCTAssertTrue(matchesRegex(components[safe: 0] ?? "", pattern: #"^\d{4}$"#), "\(label): expected year in \(relativePath)")
                    XCTAssertTrue(matchesRegex(components[safe: 1] ?? "", pattern: #"^\d{6}$"#), "\(label): expected YYYYMM in \(relativePath)")
                    index = 2
                case .yearMonthNested:
                    XCTAssertTrue(matchesRegex(components[safe: 0] ?? "", pattern: #"^\d{4}$"#), "\(label): expected year in \(relativePath)")
                    XCTAssertTrue(matchesRegex(components[safe: 1] ?? "", pattern: #"^\d{2}$"#), "\(label): expected MM in \(relativePath)")
                    index = 2
                }
            }

            if scheme.includeCameraFolder {
                XCTAssertGreaterThan(components.count, index + 1, "\(label): missing camera/media path in \(relativePath)")
                let cameraComponent = components[index]
                XCTAssertFalse(cameraComponent.isEmpty, "\(label): empty camera component in \(relativePath)")
                XCTAssertNotEqual(cameraComponent, "Photos")
                XCTAssertNotEqual(cameraComponent, "Videos")
                index += 1
            }

            XCTAssertGreaterThan(components.count, index + 1, "\(label): missing media directory in \(relativePath)")
            let mediaComponent = components[index]
            XCTAssertTrue(mediaComponent == "Photos" || mediaComponent == "Videos", "\(label): unexpected media directory in \(relativePath)")
            index += 1

            if mediaComponent == "Photos" {
                let hasCompressionDirectory = components[safe: index] == "RAW" || components[safe: index] == "Non-RAW"
                if scheme.splitPhotoCompression {
                    XCTAssertTrue(hasCompressionDirectory, "\(label): expected RAW/Non-RAW segment in \(relativePath)")
                    index += 1
                } else {
                    XCTAssertFalse(hasCompressionDirectory, "\(label): unexpected RAW/Non-RAW segment in \(relativePath)")
                }
            } else if mediaComponent == "Videos" {
                XCTAssertFalse(components[safe: index] == "RAW" || components[safe: index] == "Non-RAW", "\(label): videos should not include compression segment")
            }

            XCTAssertEqual(index, components.count - 1, "\(label): expected filename as final path component in \(relativePath)")
        }
    }

    func assertPDFSummaryArtifact(viewModel: LauncherViewModel, summaryData: [String: Any], label: String) throws {
        let summaryPath = stringValue(summaryData["pdf_summary_path"])
        XCTAssertFalse(summaryPath.isEmpty, "\(label): missing pdf_summary_path in SUMMARY payload")
        XCTAssertFalse(viewModel.pdfSummaryPath.isEmpty, "\(label): launcher UI missing pdfSummaryPath on success")

        if !summaryPath.isEmpty, !viewModel.pdfSummaryPath.isEmpty {
            let normalizedSummary = URL(fileURLWithPath: summaryPath).standardizedFileURL.path
            let normalizedViewModel = URL(fileURLWithPath: viewModel.pdfSummaryPath).standardizedFileURL.path
            XCTAssertEqual(normalizedViewModel, normalizedSummary, "\(label): view-model and summary PDF paths diverged")
        }

        let path = !summaryPath.isEmpty ? summaryPath : viewModel.pdfSummaryPath
        guard !path.isEmpty else {
            return
        }

        XCTAssertTrue(path.lowercased().hasSuffix(".pdf"), "\(label): pdf_summary_path must point to a .pdf file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(label): pdf_summary_path does not exist")
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "\(label): pdf_summary_path should point to a non-empty PDF artifact")

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let prefixData = try handle.read(upToCount: 4) ?? Data()
        let prefix = String(data: prefixData, encoding: .ascii) ?? ""
        XCTAssertEqual(prefix, "%PDF", "\(label): pdf_summary_path should contain a valid PDF header")
    }

    func totalsByOutcome(from summaryData: [String: Any]) -> [String: Any] {
        dictionaryValue(summaryData["totals_by_outcome"])
    }

    func makeViewModel(cliEnvironmentOverrides: [String: String]) -> LauncherViewModel {
        LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: LauncherSharedSourceScanner(),
            finderOpening: StubLauncherFinderOpening(),
            ingestRunnerFactory: { [cliEnvironmentOverrides] request in
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in cliEnvironmentOverrides {
                    environment[key] = value
                }
                return IngestSession.begin(
                    request: request,
                    logger: nil,
                    faultInjection: .fromEnvironment(environment)
                )
            }
        )
    }

    func stringValue(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? String, let intValue = Int(value) {
            return intValue
        }
        return 0
    }

    func boolValue(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let value = value as? String {
            return value == "true" || value == "1"
        }
        return false
    }

    func dictionaryValue(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    func arrayValue(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    func stringArray(_ value: Any?) -> [String] {
        arrayValue(value).compactMap { $0 as? String }
    }

    func matchesRegex(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
