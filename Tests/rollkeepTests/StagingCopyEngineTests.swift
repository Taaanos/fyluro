import Foundation
import XCTest
@testable import rollkeep

final class StagingCopyEngineTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-copy-engine-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCopyToStagingStreamsHashAndVerifiesReadBack() throws {
        let sourcePath = try writeSourceFile(named: "IMG_0001.JPG", bytes: Data((0..<4096).map { UInt8($0 % 251) }))
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("IMG_0001.JPG", isDirectory: false)
            .path

        let result = try XCTUnwrap(runCopy(
            jobs: [
                .init(
                    relativePath: "DCIM/100/IMG_0001.JPG",
                    sourcePath: sourcePath,
                    stagingPath: stagingPath,
                    finalPath: "/unused/final/IMG_0001.JPG",
                    expectedBytes: 4096
                ),
            ],
            configuration: .init(verifyAfterCopy: true, maxParallelCopies: 2, chunkSize: 512)
        ).first)

        XCTAssertEqual(result.bytesCopied, 4096)
        XCTAssertFalse(result.verificationSkipped)
        XCTAssertEqual(result.sourceHashSHA256, result.verifiedHashSHA256)
        XCTAssertGreaterThanOrEqual(result.copyDurationMS, 0)
        XCTAssertGreaterThanOrEqual(result.verifyDurationMS, 0)

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath, isDirectory: false))
        let stagingData = try Data(contentsOf: URL(fileURLWithPath: stagingPath, isDirectory: false))
        XCTAssertEqual(stagingData, sourceData)

        let stagingDir = URL(fileURLWithPath: stagingPath, isDirectory: false).deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
        XCTAssertFalse(entries.contains { $0.contains(".rollkeep-") && $0.hasSuffix(".tmp") })
    }

    func testCopyToStagingCanSkipVerification() throws {
        let sourceBytes = Data((0..<2048).map { UInt8($0 % 127) })
        let sourcePath = try writeSourceFile(named: "CLIP_0001.MP4", bytes: sourceBytes)
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-2", isDirectory: true)
            .appendingPathComponent("CLIP_0001.MP4", isDirectory: false)
            .path

        let result = try XCTUnwrap(runCopy(
            jobs: [
                .init(
                    relativePath: "PRIVATE/CLIP_0001.MP4",
                    sourcePath: sourcePath,
                    stagingPath: stagingPath,
                    finalPath: "/unused/final/CLIP_0001.MP4",
                    expectedBytes: Int64(sourceBytes.count)
                ),
            ],
            configuration: .init(verifyAfterCopy: false, maxParallelCopies: 1, chunkSize: 256)
        ).first)

        XCTAssertTrue(result.verificationSkipped)
        XCTAssertNil(result.verifiedHashSHA256)
        XCTAssertGreaterThanOrEqual(result.copyDurationMS, 0)
        XCTAssertEqual(result.verifyDurationMS, 0)
    }

    func testVerifyFailureReportsHashMismatchFromStagedReadBack() throws {
        let sourceBytes = Data((0..<2048).map { UInt8($0 % 193) })
        let sourcePath = try writeSourceFile(named: "IMG_3001.JPG", bytes: sourceBytes)
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-verify-fail", isDirectory: true)
            .appendingPathComponent("IMG_3001.JPG", isDirectory: false)
            .path
        let finalPath = "/unused/final/IMG_3001.JPG"

        let engine = StagingCopyEngine(
            configuration: .init(verifyAfterCopy: true, maxParallelCopies: 1, chunkSize: 256),
            onPreVerify: { job in
                guard job.relativePath == "DCIM/100/IMG_3001.JPG" else {
                    return
                }
                let corrupted = Data(repeating: 0xFF, count: Int(job.expectedBytes))
                try? corrupted.write(to: URL(fileURLWithPath: job.stagingPath, isDirectory: false))
            }
        )

        do {
            _ = try engine.copyToStaging(files: [
                .init(
                    relativePath: "DCIM/100/IMG_3001.JPG",
                    sourcePath: sourcePath,
                    stagingPath: stagingPath,
                    finalPath: finalPath,
                    expectedBytes: Int64(sourceBytes.count)
                ),
            ])
            XCTFail("Expected verify failure")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertTrue(partialResults.isEmpty)
                XCTAssertEqual(failure.phase, .verify)
                XCTAssertEqual(failure.relativePath, "DCIM/100/IMG_3001.JPG")
                XCTAssertEqual(failure.sourcePath, sourcePath)
                XCTAssertEqual(failure.stagingPath, stagingPath)
                XCTAssertEqual(failure.finalPath, finalPath)
                XCTAssertEqual(failure.expectedBytes, Int64(sourceBytes.count))
                XCTAssertEqual(failure.actualBytes, Int64(sourceBytes.count))
                XCTAssertNotNil(failure.expectedHashSHA256)
                XCTAssertNotNil(failure.actualHashSHA256)
                XCTAssertNotEqual(failure.expectedHashSHA256, failure.actualHashSHA256)
                XCTAssertEqual(failure.message, "Read-back verification failed: hash mismatch")
                XCTAssertGreaterThanOrEqual(failure.copyDurationMS, 0)
                XCTAssertGreaterThanOrEqual(failure.verifyDurationMS, 0)
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
    }

    func testCopyFailureDoesNotModifyExistingFinalPath() throws {
        let finalURL = tempRoot.appendingPathComponent("Photos/2024/202402/cam/IMG_9000.JPG", isDirectory: false)
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("existing-library-file".utf8)
        try original.write(to: finalURL)

        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-3", isDirectory: true)
            .appendingPathComponent("IMG_9000.JPG", isDirectory: false)
            .path

        let engine = StagingCopyEngine(configuration: .init(verifyAfterCopy: true, maxParallelCopies: 1, chunkSize: 512))

        do {
            _ = try engine.copyToStaging(files: [
                .init(
                    relativePath: "DCIM/100/IMG_9000.JPG",
                    sourcePath: tempRoot.appendingPathComponent("missing.JPG", isDirectory: false).path,
                    stagingPath: stagingPath,
                    finalPath: finalURL.path,
                    expectedBytes: 100
                ),
            ])
            XCTFail("Expected copy to fail for missing source")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(_, let failure):
                XCTAssertEqual(failure.phase, .copy)
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }

        let postFailure = try Data(contentsOf: finalURL)
        XCTAssertEqual(postFailure, original)
    }

    func testCopyRespectsConcurrencyLimit() throws {
        let lock = NSLock()
        var active = 0
        var peak = 0

        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        var jobs: [StagingCopyEngine.FileJob] = []
        for index in 0..<6 {
            let filename = "IMG_\(index).JPG"
            let sourcePath = sourceDir.appendingPathComponent(filename, isDirectory: false).path
            let bytes = Data((0..<1024).map { UInt8(($0 + index) % 241) })
            try bytes.write(to: URL(fileURLWithPath: sourcePath, isDirectory: false))

            let stagingPath = tempRoot
                .appendingPathComponent("_ingest_staging", isDirectory: true)
                .appendingPathComponent("session-4", isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
                .path

            jobs.append(.init(
                relativePath: "DCIM/100/\(filename)",
                sourcePath: sourcePath,
                stagingPath: stagingPath,
                finalPath: "/unused/final/\(filename)",
                expectedBytes: Int64(bytes.count)
            ))
        }

        let engine = StagingCopyEngine(
            configuration: .init(verifyAfterCopy: false, maxParallelCopies: 2, chunkSize: 256),
            onEvent: { event in
                switch event {
                case .started:
                    lock.lock()
                    active += 1
                    if active > peak {
                        peak = active
                    }
                    lock.unlock()
                    usleep(100_000)
                case .finished:
                    lock.lock()
                    active -= 1
                    lock.unlock()
                }
            }
        )

        let results = try engine.copyToStaging(files: jobs)
        XCTAssertEqual(results.count, jobs.count)
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(peak, 2)
    }

    private func runCopy(
        jobs: [StagingCopyEngine.FileJob],
        configuration: StagingCopyEngine.Configuration
    ) throws -> [StagingCopyEngine.FileResult] {
        try StagingCopyEngine(configuration: configuration).copyToStaging(files: jobs)
    }

    private func writeSourceFile(named name: String, bytes: Data) throws -> String {
        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let fileURL = sourceDir.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: fileURL)
        return fileURL.path
    }
}
