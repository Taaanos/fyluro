import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import FyluroEngine

final class StagingCopyEngineTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-copy-engine-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // KI-1: the hidden temporary name must not depend on the filename length.
    // 254 bytes is a legal name on APFS, HFS+ and exFAT (limit 255 per component).
    func testCopyToStagingAcceptsFilenameNearComponentLimit() throws {
        let longName = String(repeating: "L", count: 250) + ".jpg"
        XCTAssertEqual(longName.utf8.count, 254)
        let sourceBytes = Data((0..<1024).map { UInt8($0 % 241) })
        let sourcePath = try writeSourceFile(named: longName, bytes: sourceBytes)
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent(longName, isDirectory: false)
            .path

        let result = try XCTUnwrap(runCopy(
            jobs: [
                .init(
                    relativePath: "DCIM/100/\(longName)",
                    sourcePath: sourcePath,
                    stagingPath: stagingPath,
                    finalPath: "/unused/final/\(longName)",
                    expectedBytes: Int64(sourceBytes.count)
                ),
            ],
            configuration: .init(verifyAfterCopy: true, maxParallelCopies: 1, chunkSize: 256)
        ).first)

        XCTAssertEqual(result.bytesCopied, Int64(sourceBytes.count))
        XCTAssertEqual(result.sourceHashSHA256, result.verifiedHashSHA256)
        let stagingData = try Data(contentsOf: URL(fileURLWithPath: stagingPath, isDirectory: false))
        XCTAssertEqual(stagingData, sourceBytes)

        let stagingDir = URL(fileURLWithPath: stagingPath, isDirectory: false).deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
        XCTAssertEqual(entries, [longName], "no temporary file may remain next to the staged file")
    }

    func testCopyToStagingFailsWhenSourcePathIsSymlink() throws {
        let sourceBytes = Data((0..<1024).map { UInt8($0 % 191) })
        let realSourcePath = try writeSourceFile(named: "IMG_REAL.JPG", bytes: sourceBytes)
        let symlinkPath = tempRoot.appendingPathComponent("source/IMG_LINK.JPG", isDirectory: false).path
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realSourcePath)

        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-symlink", isDirectory: true)
            .appendingPathComponent("IMG_LINK.JPG", isDirectory: false)
            .path

        do {
            _ = try runCopy(
                jobs: [
                    .init(
                        relativePath: "DCIM/100/IMG_LINK.JPG",
                        sourcePath: symlinkPath,
                        stagingPath: stagingPath,
                        finalPath: "/unused/final/IMG_LINK.JPG",
                        expectedBytes: Int64(sourceBytes.count)
                    ),
                ],
                configuration: .init(verifyAfterCopy: true, maxParallelCopies: 1, chunkSize: 512)
            )
            XCTFail("Expected copy failure for symlink source")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertTrue(partialResults.isEmpty)
                XCTAssertEqual(failure.phase, .copy)
                XCTAssertEqual(failure.relativePath, "DCIM/100/IMG_LINK.JPG")
                XCTAssertEqual(failure.message, "symlink_not_allowed: source path is a symbolic link")
                XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
    }

    func testCopyToStagingFailsImmediatelyWhenSourcePathIsFIFO() throws {
        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let fifoPath = sourceDir.appendingPathComponent("IMG_PIPE.JPG", isDirectory: false).path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "mkfifo failed: \(errno)")

        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-fifo", isDirectory: true)
            .appendingPathComponent("IMG_PIPE.JPG", isDirectory: false)
            .path

        do {
            _ = try runCopy(
                jobs: [
                    .init(
                        relativePath: "DCIM/100/IMG_PIPE.JPG",
                        sourcePath: fifoPath,
                        stagingPath: stagingPath,
                        finalPath: "/unused/final/IMG_PIPE.JPG",
                        expectedBytes: 0
                    ),
                ],
                configuration: .init(verifyAfterCopy: true, maxParallelCopies: 1, chunkSize: 512)
            )
            XCTFail("Expected copy failure for FIFO source")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertTrue(partialResults.isEmpty)
                XCTAssertEqual(failure.phase, .copy)
                XCTAssertEqual(failure.message, "non_regular_source: source path is not a regular file")
                XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
    }

    func testTwoPassHardwareVerificationCopiesAllFlushesOnceThenVerifiesAll() throws {
        let stagingDir = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-hw-on", isDirectory: true)
        var jobs: [StagingCopyEngine.FileJob] = []
        for index in 0..<3 {
            let name = "IMG_HW_\(index).JPG"
            let bytes = Data((0..<4096).map { UInt8(($0 + index) % 239) })
            let sourcePath = try writeSourceFile(named: name, bytes: bytes)
            jobs.append(.init(
                relativePath: "DCIM/100/\(name)",
                sourcePath: sourcePath,
                stagingPath: stagingDir.appendingPathComponent(name, isDirectory: false).path,
                finalPath: "/unused/final/\(name)",
                expectedBytes: Int64(bytes.count)
            ))
        }

        var timeline: [String] = []
        var writeNoCacheCalls = 0
        var syncVolumeCalls = 0
        var readNoCacheCalls = 0
        let systemHooks = StagingCopyEngine.FileDescriptorHooks.system
        let hooks = StagingCopyEngine.FileDescriptorHooks(
            disableStagingWriteCache: { fd in
                writeNoCacheCalls += 1
                timeline.append("write_nocache")
                return systemHooks.disableStagingWriteCache(fd)
            },
            syncStagingVolume: { fd in
                syncVolumeCalls += 1
                timeline.append("sync_volume")
                return systemHooks.syncStagingVolume(fd)
            },
            disableReadBackCache: { fd in
                readNoCacheCalls += 1
                timeline.append("read_nocache")
                return systemHooks.disableReadBackCache(fd)
            }
        )

        let defaultConfig = StagingCopyEngine.Configuration()
        XCTAssertTrue(defaultConfig.hardwareVerification)

        var verifyPhaseStartedCalls = 0
        var verifiedPaths: [String] = []
        var verifyProgressByPath: [String: Int64] = [:]

        let engine = StagingCopyEngine(
            configuration: defaultConfig,
            fileDescriptorHooks: hooks,
            onVerifyPhaseStarted: {
                verifyPhaseStartedCalls += 1
                timeline.append("verify_phase_started")
            },
            onVerifyProgress: { job, bytes in
                verifyProgressByPath[job.relativePath] = bytes
            },
            onFileVerified: { job in
                verifiedPaths.append(job.relativePath)
                timeline.append("verified:\(job.relativePath)")
            }
        )
        let results = try engine.copyToStaging(files: jobs)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(writeNoCacheCalls, 3)
        XCTAssertEqual(syncVolumeCalls, 1)
        XCTAssertEqual(readNoCacheCalls, 3)
        XCTAssertEqual(verifyPhaseStartedCalls, 1)
        XCTAssertEqual(verifiedPaths, jobs.map(\.relativePath))
        for job in jobs {
            XCTAssertEqual(verifyProgressByPath[job.relativePath], job.expectedBytes)
        }
        for result in results {
            XCTAssertFalse(result.verificationSkipped)
            XCTAssertEqual(result.sourceHashSHA256, result.verifiedHashSHA256)
        }
        XCTAssertEqual(Array(timeline.prefix(5)), [
            "write_nocache", "write_nocache", "write_nocache", "sync_volume", "verify_phase_started",
        ])
    }

    func testHardwareVerificationGateSkipsNoCacheAndSyncWhenDisabled() throws {
        let sourceBytes = Data((0..<2048).map { UInt8($0 % 229) })
        let sourcePath = try writeSourceFile(named: "IMG_HW_OFF.JPG", bytes: sourceBytes)
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-hw-off", isDirectory: true)
            .appendingPathComponent("IMG_HW_OFF.JPG", isDirectory: false)
            .path

        var writeNoCacheCalls = 0
        var syncVolumeCalls = 0
        var readNoCacheCalls = 0
        let hooks = StagingCopyEngine.FileDescriptorHooks(
            disableStagingWriteCache: { _ in
                writeNoCacheCalls += 1
                return 0
            },
            syncStagingVolume: { _ in
                syncVolumeCalls += 1
                return 0
            },
            disableReadBackCache: { _ in
                readNoCacheCalls += 1
                return 0
            }
        )

        let engine = StagingCopyEngine(
            configuration: .init(
                verifyAfterCopy: true,
                hardwareVerification: false,
                maxParallelCopies: 1,
                chunkSize: 512
            ),
            fileDescriptorHooks: hooks
        )
        let result = try XCTUnwrap(engine.copyToStaging(files: [
            .init(
                relativePath: "DCIM/100/IMG_HW_OFF.JPG",
                sourcePath: sourcePath,
                stagingPath: stagingPath,
                finalPath: "/unused/final/IMG_HW_OFF.JPG",
                expectedBytes: Int64(sourceBytes.count)
            ),
        ]).first)

        XCTAssertEqual(writeNoCacheCalls, 0)
        XCTAssertEqual(syncVolumeCalls, 0)
        XCTAssertEqual(readNoCacheCalls, 0)
        XCTAssertEqual(result.sourceHashSHA256, result.verifiedHashSHA256)
    }

    func testHardwareVerificationFlushFailureFailsInCopyPhaseAndRetainsStagedFiles() throws {
        let stagingDir = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-flush-fail", isDirectory: true)
        var jobs: [StagingCopyEngine.FileJob] = []
        for index in 0..<2 {
            let name = "IMG_FLUSH_\(index).JPG"
            let bytes = Data((0..<1024).map { UInt8(($0 + index) % 227) })
            let sourcePath = try writeSourceFile(named: name, bytes: bytes)
            jobs.append(.init(
                relativePath: "DCIM/100/\(name)",
                sourcePath: sourcePath,
                stagingPath: stagingDir.appendingPathComponent(name, isDirectory: false).path,
                finalPath: "/unused/final/\(name)",
                expectedBytes: Int64(bytes.count)
            ))
        }

        let hooks = StagingCopyEngine.FileDescriptorHooks(
            disableStagingWriteCache: { _ in 0 },
            syncStagingVolume: { _ in
                errno = EIO
                return -1
            },
            disableReadBackCache: { _ in 0 }
        )

        let engine = StagingCopyEngine(
            configuration: .init(verifyAfterCopy: true, hardwareVerification: true, maxParallelCopies: 1, chunkSize: 256),
            fileDescriptorHooks: hooks
        )

        do {
            _ = try engine.copyToStaging(files: jobs)
            XCTFail("Expected copy failure when staging volume flush fails")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertEqual(partialResults.count, 1)
                XCTAssertTrue(partialResults[0].verificationSkipped)
                XCTAssertNil(partialResults[0].verifiedHashSHA256)
                XCTAssertEqual(failure.phase, .copy)
                XCTAssertEqual(failure.relativePath, "DCIM/100/IMG_FLUSH_1.JPG")
                XCTAssertTrue(failure.message.contains("Failed to flush staging volume to disk"))
                // Both staged files remain on disk as evidence (I-7).
                XCTAssertTrue(FileManager.default.fileExists(atPath: jobs[0].stagingPath))
                XCTAssertTrue(FileManager.default.fileExists(atPath: jobs[1].stagingPath))
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
    }

    func testHardwareVerificationNoCacheFailureFailsInVerifyPhaseAndRetainsStagedFile() throws {
        let sourceBytes = Data((0..<1024).map { UInt8($0 % 223) })
        let sourcePath = try writeSourceFile(named: "IMG_NOCACHE_FAIL.JPG", bytes: sourceBytes)
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-nocache-fail", isDirectory: true)
            .appendingPathComponent("IMG_NOCACHE_FAIL.JPG", isDirectory: false)
            .path

        let hooks = StagingCopyEngine.FileDescriptorHooks(
            disableStagingWriteCache: { _ in 0 },
            syncStagingVolume: { _ in 0 },
            disableReadBackCache: { _ in
                errno = EIO
                return -1
            }
        )

        let engine = StagingCopyEngine(
            configuration: .init(verifyAfterCopy: true, hardwareVerification: true, maxParallelCopies: 1, chunkSize: 256),
            fileDescriptorHooks: hooks
        )

        do {
            _ = try engine.copyToStaging(files: [
                .init(
                    relativePath: "DCIM/100/IMG_NOCACHE_FAIL.JPG",
                    sourcePath: sourcePath,
                    stagingPath: stagingPath,
                    finalPath: "/unused/final/IMG_NOCACHE_FAIL.JPG",
                    expectedBytes: Int64(sourceBytes.count)
                ),
            ])
            XCTFail("Expected verify failure when F_NOCACHE fails")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertTrue(partialResults.isEmpty)
                XCTAssertEqual(failure.phase, .verify)
                XCTAssertTrue(failure.message.contains("Failed to disable read-back cache"))
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
    }

    func testVerifyPassCancellationStopsMidFileAndRetainsStagedFiles() throws {
        let sourceBytes = Data((0..<4096).map { UInt8($0 % 211) })
        let sourcePath = try writeSourceFile(named: "IMG_CANCEL_VERIFY.JPG", bytes: sourceBytes)
        let stagingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-cancel-verify", isDirectory: true)
            .appendingPathComponent("IMG_CANCEL_VERIFY.JPG", isDirectory: false)
            .path

        var cancelled = false
        let engine = StagingCopyEngine(
            configuration: .init(verifyAfterCopy: true, hardwareVerification: true, maxParallelCopies: 1, chunkSize: 512),
            onVerifyProgress: { _, bytesVerified in
                if bytesVerified >= 512 {
                    cancelled = true
                }
            },
            shouldCancel: { cancelled }
        )

        do {
            _ = try engine.copyToStaging(files: [
                .init(
                    relativePath: "DCIM/100/IMG_CANCEL_VERIFY.JPG",
                    sourcePath: sourcePath,
                    stagingPath: stagingPath,
                    finalPath: "/unused/final/IMG_CANCEL_VERIFY.JPG",
                    expectedBytes: Int64(sourceBytes.count)
                ),
            ])
            XCTFail("Expected verify cancellation failure")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertTrue(partialResults.isEmpty)
                XCTAssertEqual(failure.phase, .verify)
                XCTAssertEqual(failure.message, "Ingest cancelled during verify")
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
    }

    func testVerifyFailureMidBatchSeparatesVerifiedAndUnverifiedPartialResults() throws {
        let stagingDir = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("session-mid-verify-fail", isDirectory: true)
        var jobs: [StagingCopyEngine.FileJob] = []
        for index in 0..<3 {
            let name = "IMG_BATCH_\(index).JPG"
            let bytes = Data((0..<1024).map { UInt8(($0 + index) % 199) })
            let sourcePath = try writeSourceFile(named: name, bytes: bytes)
            jobs.append(.init(
                relativePath: "DCIM/100/\(name)",
                sourcePath: sourcePath,
                stagingPath: stagingDir.appendingPathComponent(name, isDirectory: false).path,
                finalPath: "/unused/final/\(name)",
                expectedBytes: Int64(bytes.count)
            ))
        }

        let engine = StagingCopyEngine(
            configuration: .init(verifyAfterCopy: true, hardwareVerification: true, maxParallelCopies: 1, chunkSize: 256),
            onPreVerify: { job in
                guard job.relativePath == "DCIM/100/IMG_BATCH_1.JPG" else {
                    return
                }
                let corrupted = Data(repeating: 0xAA, count: Int(job.expectedBytes))
                try? corrupted.write(to: URL(fileURLWithPath: job.stagingPath, isDirectory: false))
            }
        )

        do {
            _ = try engine.copyToStaging(files: jobs)
            XCTFail("Expected verify failure on second file")
        } catch let error as StagingCopyEngine.EngineError {
            switch error {
            case .runFailed(let partialResults, let failure):
                XCTAssertEqual(failure.phase, .verify)
                XCTAssertEqual(failure.relativePath, "DCIM/100/IMG_BATCH_1.JPG")
                // File 0 was verified; File 2 was copied in Pass 1 but never verified.
                XCTAssertEqual(partialResults.count, 2)
                XCTAssertEqual(partialResults[0].relativePath, "DCIM/100/IMG_BATCH_0.JPG")
                XCTAssertFalse(partialResults[0].verificationSkipped)
                XCTAssertNotNil(partialResults[0].verifiedHashSHA256)
                XCTAssertEqual(partialResults[1].relativePath, "DCIM/100/IMG_BATCH_2.JPG")
                XCTAssertTrue(partialResults[1].verificationSkipped)
                XCTAssertNil(partialResults[1].verifiedHashSHA256)
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration failure")
            }
        }
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
