import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeep

final class CLIIngestHelpersTests: XCTestCase {
    func testParsePositiveIntParsesAndRejectsInvalidValues() {
        XCTAssertEqual(
            CLIIngestEnvironmentParsing.parsePositiveInt(
                name: "ROLLKEEP_TEST_VALUE",
                environment: ["ROLLKEEP_TEST_VALUE": " 42 "]
            ),
            42
        )
        XCTAssertNil(CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_VALUE", environment: [:]))
        XCTAssertNil(CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_VALUE", environment: ["ROLLKEEP_TEST_VALUE": "0"]))
        XCTAssertNil(CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_VALUE", environment: ["ROLLKEEP_TEST_VALUE": "-3"]))
        XCTAssertNil(CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_VALUE", environment: ["ROLLKEEP_TEST_VALUE": "abc"]))
    }

    func testParseRelativePathSetTrimsDropsEmptyAndDedupes() {
        let parsed = CLIIngestEnvironmentParsing.parseRelativePathSet(
            name: "ROLLKEEP_TEST_PATHS",
            environment: ["ROLLKEEP_TEST_PATHS": " DCIM/A.JPG , PRIVATE/B.MP4, ,DCIM/A.JPG "]
        )

        XCTAssertEqual(parsed, Set(["DCIM/A.JPG", "PRIVATE/B.MP4"]))
    }

    func testFailureContextResolverMapsSourceScannerErrors() {
        let unreadable = CLIIngestFailureContextResolver.resolve(SourceScannerError.unreadableSourceRoot("/card"))
        XCTAssertEqual(unreadable.phase, .scan)
        XCTAssertTrue(unreadable.message.contains("Source root unreadable"))

        let symlink = CLIIngestFailureContextResolver.resolve(SourceScannerError.symbolicLinkDetected("/card/DCIM/link"))
        XCTAssertEqual(symlink.phase, .scan)
        XCTAssertTrue(symlink.message.contains("symlink"))

        let boundary = CLIIngestFailureContextResolver.resolve(
            SourceScannerError.sourceBoundaryViolation(path: "/tmp/a", sourceRoot: "/card")
        )
        XCTAssertEqual(boundary.phase, .scan)
        XCTAssertTrue(boundary.message.contains("boundary violation"))
    }

    func testFailureContextResolverMapsIngestRuntimeError() {
        let context = CLIIngestFailureContextResolver.resolve(
            IngestRuntimeError(phase: .verify, message: "hash mismatch")
        )

        XCTAssertEqual(context.phase, .verify)
        XCTAssertEqual(context.message, "hash mismatch")
    }

    func testFailureContextResolverFallsBackToFinalizeForUnknownErrors() {
        struct UnknownError: LocalizedError {
            var errorDescription: String? { "boom" }
        }

        let context = CLIIngestFailureContextResolver.resolve(UnknownError())
        XCTAssertEqual(context.phase, .finalize)
        XCTAssertEqual(context.message, "boom")
    }

    func testSummaryBuilderVerifiedOkRequiresCommitAndMatchingVerifiedCounts() throws {
        let command = try makeCommand()
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-summary-builder-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let receiptWriter = try ReceiptWriter(destRoot: tempRoot, sessionID: "session-1")
        let isoFormatter = ISO8601DateFormatter()
        var totals = ReceiptOutcomeTotals()
        totals.copied = 2
        totals.verified = 2
        totals.committed = 2

        let verifiedSummary = command.buildSummaryData(
            finalStatus: "completed",
            dryRun: false,
            commitStageCompleted: true,
            scanSummary: nil,
            destinationPlan: nil,
            cardAssessment: nil,
            outcomeTotals: totals,
            touchedPaths: ReceiptTouchedPaths(),
            receiptWriter: receiptWriter,
            pdfSummaryPath: nil,
            phaseTimings: PhaseTimingTracker(),
            isoFormatter: isoFormatter,
            pathSchemeString: "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename>"
        )

        XCTAssertEqual(verifiedSummary["verified_ok"] as? Bool, true)

        totals.verified = 1
        let mismatchedSummary = command.buildSummaryData(
            finalStatus: "completed",
            dryRun: false,
            commitStageCompleted: true,
            scanSummary: nil,
            destinationPlan: nil,
            cardAssessment: nil,
            outcomeTotals: totals,
            touchedPaths: ReceiptTouchedPaths(),
            receiptWriter: receiptWriter,
            pdfSummaryPath: nil,
            phaseTimings: PhaseTimingTracker(),
            isoFormatter: isoFormatter,
            pathSchemeString: "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename>"
        )

        XCTAssertEqual(mismatchedSummary["verified_ok"] as? Bool, false)
    }

    func testSummaryBuilderPerFileOutcomesTrackExecutedFromTouchedPaths() throws {
        let command = try makeCommand()
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-summary-per-file-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let stagedCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/IMG_0001.JPG",
            relativePath: "DCIM/IMG_0001.JPG",
            mediaType: .photo,
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_000),
                captureDateSource: .dateTimeOriginal,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        )

        let duplicateCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/IMG_0002.JPG",
            relativePath: "DCIM/IMG_0002.JPG",
            mediaType: .photo,
            sizeBytes: 120,
            mtime: Date(timeIntervalSince1970: 1_700_000_010),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_010),
                captureDateSource: .dateTimeOriginal,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        )

        let plannedStage = DestinationPathPlanner.PlannedFile(
            candidate: stagedCandidate,
            cameraLabel: "camera-a",
            sourceHash: nil,
            finalPath: "/dest/2023/202311/camera-a/Photos/IMG_0001.JPG",
            stagingPath: "/dest/_ingest_staging/session-1/2023/202311/camera-a/Photos/IMG_0001.JPG",
            disposition: .stageAndCommit,
            collisionResolved: false,
            collisionSuffix: nil,
            duplicateOfPath: nil,
            photoCompressionBucket: nil
        )

        let plannedDuplicate = DestinationPathPlanner.PlannedFile(
            candidate: duplicateCandidate,
            cameraLabel: "camera-a",
            sourceHash: nil,
            finalPath: "/dest/2023/202311/camera-a/Photos/IMG_0002.JPG",
            stagingPath: nil,
            disposition: .duplicateNotCopied,
            collisionResolved: false,
            collisionSuffix: nil,
            duplicateOfPath: "/dest/2023/202311/camera-a/Photos/IMG_0002.JPG",
            photoCompressionBucket: nil
        )

        let plan = DestinationPathPlanner.Plan(
            files: [plannedStage, plannedDuplicate],
            directoriesToCreate: []
        )

        var touchedPaths = ReceiptTouchedPaths()
        touchedPaths.addWrittenStagingFile(try XCTUnwrap(plannedStage.stagingPath))

        let receiptWriter = try ReceiptWriter(destRoot: tempRoot, sessionID: "session-2")

        let summary = command.buildSummaryData(
            finalStatus: "completed",
            dryRun: false,
            commitStageCompleted: true,
            scanSummary: nil,
            destinationPlan: plan,
            cardAssessment: nil,
            outcomeTotals: ReceiptOutcomeTotals(),
            touchedPaths: touchedPaths,
            receiptWriter: receiptWriter,
            pdfSummaryPath: nil,
            phaseTimings: PhaseTimingTracker(),
            isoFormatter: ISO8601DateFormatter(),
            pathSchemeString: "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename>"
        )

        let outcomes = try XCTUnwrap(summary["per_file_outcomes"] as? [[String: Any]])
        let stageOutcome = try XCTUnwrap(outcomes.first(where: { ($0["path"] as? String) == "DCIM/IMG_0001.JPG" }))
        let duplicateOutcome = try XCTUnwrap(outcomes.first(where: { ($0["path"] as? String) == "DCIM/IMG_0002.JPG" }))

        XCTAssertEqual(stageOutcome["executed"] as? Bool, true)
        XCTAssertEqual(duplicateOutcome["executed"] as? Bool, false)
    }

    func testTouchedPathsPayloadAlwaysIncludesActiveReceiptPath() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-touched-paths-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let receiptWriter = try ReceiptWriter(destRoot: tempRoot, sessionID: "session-3")

        var touchedPaths = ReceiptTouchedPaths()
        touchedPaths.addWrittenReceiptFile("/tmp/custom-receipt.ndjson")

        let payload = touchedPaths.payload(with: receiptWriter)
        let receiptPaths = try XCTUnwrap(payload["written_receipt_files"] as? [String])

        XCTAssertTrue(receiptPaths.contains("/tmp/custom-receipt.ndjson"))
        XCTAssertTrue(receiptPaths.contains(receiptWriter.sink.path))
    }

    private func makeCommand() throws -> RollkeepCLI {
        try RollkeepCLI.parse([
            "--source", "/tmp/source",
            "--dest", "/tmp/dest",
        ])
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = root.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}
