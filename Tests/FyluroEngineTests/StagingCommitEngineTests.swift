import CommonCrypto
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import FyluroCore
@testable import FyluroEngine

final class StagingCommitEngineTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-commit-engine-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCommitMovesStagingFileToPlannedFinalPath() throws {
        let bytes = Data((0..<2048).map { UInt8($0 % 251) })
        let stagingPath = try writeFile(path: "_ingest_staging/session-1/Photos/2026/202603/cam/IMG_0001.JPG", bytes: bytes)
        let finalPath = tempRoot
            .appendingPathComponent("Photos/2026/202603/cam/IMG_0001.JPG", isDirectory: false)
            .path
        let sourceModificationDate = Date(timeIntervalSince1970: 1_734_321_234)
        let sourceCreationDate = Date(timeIntervalSince1970: 1_734_320_000)

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0001.JPG",
            sourcePath: "/source/DCIM/100/IMG_0001.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes),
            sourceModificationDate: sourceModificationDate,
            sourceCreationDate: sourceCreationDate
        )

        let result = try XCTUnwrap(try StagingCommitEngine(destinationRoot: tempRoot).commit(files: [job]).first)
        XCTAssertEqual(result.disposition, .committed)
        XCTAssertEqual(result.finalPath, finalPath)
        XCTAssertFalse(result.collisionResolved)
        XCTAssertEqual(result.moveStrategy, .rename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath))

        let finalBytes = try Data(contentsOf: URL(fileURLWithPath: finalPath, isDirectory: false))
        XCTAssertEqual(finalBytes, bytes)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: finalPath)
        XCTAssertEqual(
            (finalAttributes[.modificationDate] as? Date)?.timeIntervalSince1970,
            sourceModificationDate.timeIntervalSince1970
        )
        XCTAssertEqual(
            (finalAttributes[.creationDate] as? Date)?.timeIntervalSince1970,
            sourceCreationDate.timeIntervalSince1970
        )
    }

    func testCommitAddsDeterministicSuffixWhenFinalPathAlreadyExists() throws {
        let stagingBytes = Data(repeating: 0xAB, count: 1024)
        let existingBytes = Data(repeating: 0xCD, count: 1024)
        let stagingPath = try writeFile(path: "_ingest_staging/session-2/Photos/2026/202603/cam/IMG_0100.JPG", bytes: stagingBytes)
        let finalPath = try writeFile(path: "Photos/2026/202603/cam/IMG_0100.JPG", bytes: existingBytes)

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0100.JPG",
            sourcePath: "/source/DCIM/100/IMG_0100.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(stagingBytes.count),
            sourceHashSHA256: sha256Hex(stagingBytes)
        )

        let result = try XCTUnwrap(try StagingCommitEngine(destinationRoot: tempRoot).commit(files: [job]).first)
        XCTAssertEqual(result.disposition, .committed)
        XCTAssertEqual(result.finalPath, tempRoot.appendingPathComponent("Photos/2026/202603/cam/IMG_0100-1.JPG", isDirectory: false).path)
        XCTAssertTrue(result.collisionResolved)
        XCTAssertEqual(result.collisionSuffix, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath))
    }

    func testCommitSkipsDuplicateWhenExistingFinalMatchesHash() throws {
        let bytes = Data((0..<512).map { UInt8(($0 * 7) % 255) })
        let stagingPath = try writeFile(path: "_ingest_staging/session-3/Photos/2026/202603/cam/IMG_0200.JPG", bytes: bytes)
        let finalPath = try writeFile(path: "Photos/2026/202603/cam/IMG_0200.JPG", bytes: bytes)

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0200.JPG",
            sourcePath: "/source/DCIM/100/IMG_0200.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        let result = try XCTUnwrap(try StagingCommitEngine(destinationRoot: tempRoot).commit(files: [job]).first)
        XCTAssertEqual(result.disposition, .duplicateNotCopied)
        XCTAssertEqual(result.finalPath, finalPath)
        XCTAssertEqual(result.moveStrategy, .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
    }

    func testCommitTreatsPlannedCollisionSuffixAsDuplicateWhenBaseMatchesHash() throws {
        let bytes = Data((0..<1024).map { UInt8(($0 * 11) % 251) })
        let existingBasePath = try writeFile(path: "Photos/2026/202603/cam/IMG_0250.JPG", bytes: bytes)
        let stagingPath = try writeFile(path: "_ingest_staging/session-3/Photos/2026/202603/cam/IMG_0250-1.JPG", bytes: bytes)

        let plannedFinalPath = tempRoot
            .appendingPathComponent("Photos/2026/202603/cam/IMG_0250-1.JPG", isDirectory: false)
            .path

        let job = StagingCommitEngine.FileJob(
            relativePath: "PRIVATE/IMG_0250.JPG",
            sourcePath: "/source/PRIVATE/IMG_0250.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: plannedFinalPath,
            plannedCollisionSuffix: 1,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        let result = try XCTUnwrap(try StagingCommitEngine(destinationRoot: tempRoot).commit(files: [job]).first)
        XCTAssertEqual(result.disposition, .duplicateNotCopied)
        XCTAssertEqual(result.finalPath, existingBasePath)
        XCTAssertEqual(result.collisionSuffix, nil)
        XCTAssertEqual(result.moveStrategy, .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plannedFinalPath))
    }

    func testCommitFailureReturnsPartialAndRemainingWork() throws {
        let firstBytes = Data(repeating: 0x01, count: 64)
        let thirdBytes = Data(repeating: 0x03, count: 64)

        let firstStaging = try writeFile(path: "_ingest_staging/session-4/Photos/2026/202603/cam/IMG_0300.JPG", bytes: firstBytes)
        let thirdStaging = try writeFile(path: "_ingest_staging/session-4/Photos/2026/202603/cam/IMG_0302.JPG", bytes: thirdBytes)

        let firstFinal = tempRoot.appendingPathComponent("Photos/2026/202603/cam/IMG_0300.JPG", isDirectory: false).path
        let secondFinal = tempRoot.appendingPathComponent("Photos/2026/202603/cam/IMG_0301.JPG", isDirectory: false).path
        let thirdFinal = tempRoot.appendingPathComponent("Photos/2026/202603/cam/IMG_0302.JPG", isDirectory: false).path

        let jobs: [StagingCommitEngine.FileJob] = [
            .init(
                relativePath: "DCIM/100/IMG_0300.JPG",
                sourcePath: "/source/DCIM/100/IMG_0300.JPG",
                stagingPath: firstStaging,
                plannedFinalPath: firstFinal,
                bytesCopied: Int64(firstBytes.count),
                sourceHashSHA256: sha256Hex(firstBytes)
            ),
            .init(
                relativePath: "DCIM/100/IMG_0301.JPG",
                sourcePath: "/source/DCIM/100/IMG_0301.JPG",
                stagingPath: tempRoot.appendingPathComponent("_ingest_staging/session-4/Photos/2026/202603/cam/IMG_0301.JPG", isDirectory: false).path,
                plannedFinalPath: secondFinal,
                bytesCopied: 64,
                sourceHashSHA256: String(repeating: "0", count: 64)
            ),
            .init(
                relativePath: "DCIM/100/IMG_0302.JPG",
                sourcePath: "/source/DCIM/100/IMG_0302.JPG",
                stagingPath: thirdStaging,
                plannedFinalPath: thirdFinal,
                bytesCopied: Int64(thirdBytes.count),
                sourceHashSHA256: sha256Hex(thirdBytes)
            ),
        ]

        do {
            _ = try StagingCommitEngine(destinationRoot: tempRoot).commit(files: jobs)
            XCTFail("Expected commit to fail for missing second staging file")
        } catch let error as StagingCommitEngine.EngineError {
            switch error {
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration error")
            case .runFailed(let partialResults, let remaining, let failure):
                XCTAssertEqual(partialResults.count, 1)
                XCTAssertEqual(partialResults.first?.relativePath, "DCIM/100/IMG_0300.JPG")
                XCTAssertEqual(remaining.count, 1)
                XCTAssertEqual(remaining.first?.relativePath, "DCIM/100/IMG_0302.JPG")
                XCTAssertEqual(failure.relativePath, "DCIM/100/IMG_0301.JPG")
                XCTAssertEqual(failure.phase, .commit)

                XCTAssertTrue(FileManager.default.fileExists(atPath: firstFinal))
                XCTAssertTrue(FileManager.default.fileExists(atPath: thirdStaging))
                XCTAssertFalse(FileManager.default.fileExists(atPath: thirdFinal))
            }
        }
    }

    func testCommitUsesCopyFallbackOnCrossVolumeMoveError() throws {
        let bytes = Data((0..<1024).map { UInt8($0 % 199) })
        let stagingPath = try writeFile(path: "_ingest_staging/session-5/Photos/2026/202603/cam/IMG_0400.JPG", bytes: bytes)
        let finalPath = tempRoot.appendingPathComponent("Photos/2026/202603/cam/IMG_0400.JPG", isDirectory: false).path

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0400.JPG",
            sourcePath: "/source/DCIM/100/IMG_0400.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        let simulatedFileManager = SimulatedCrossVolumeMoveFileManager()
        let result = try XCTUnwrap(
            try StagingCommitEngine(destinationRoot: tempRoot, fileManager: simulatedFileManager).commit(files: [job]).first
        )

        XCTAssertEqual(result.moveStrategy, .copyThenRemove)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
    }

    func testCommitFailsWhenBeforeMoveHookThrows() throws {
        let bytes = Data((0..<1024).map { UInt8($0 % 199) })
        let stagingPath = try writeFile(path: "_ingest_staging/session-before-move/Photos/2026/202603/cam/IMG_0600.JPG", bytes: bytes)
        let finalPath = tempRoot.appendingPathComponent("Photos/2026/202603/cam/IMG_0600.JPG", isDirectory: false).path

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0600.JPG",
            sourcePath: "/source/DCIM/100/IMG_0600.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        do {
            _ = try StagingCommitEngine(destinationRoot: tempRoot, onBeforeMove: { _, _ in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EIO),
                    userInfo: [NSLocalizedDescriptionKey: "Simulated commit failure"]
                )
            }).commit(files: [job])
            XCTFail("Expected commit failure from before-move hook")
        } catch let error as StagingCommitEngine.EngineError {
            switch error {
            case .invalidConfiguration:
                XCTFail("Unexpected invalid configuration error")
            case .runFailed(let partialResults, let remaining, let failure):
                XCTAssertTrue(partialResults.isEmpty)
                XCTAssertTrue(remaining.isEmpty)
                XCTAssertEqual(failure.phase, .commit)
                XCTAssertEqual(failure.message, "Simulated commit failure")
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
                XCTAssertFalse(FileManager.default.fileExists(atPath: finalPath))
            }
        }
    }

    func testCommitReusesExistingLowercaseMediaDirectory() throws {
        let bytes = Data((0..<1024).map { UInt8(($0 * 3) % 251) })
        let stagingPath = try writeFile(path: "_ingest_staging/session-6/Photos/2026/202603/cam/IMG_0500.JPG", bytes: bytes)
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("photos/2026/202603/cam", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plannedFinalPath = tempRoot
            .appendingPathComponent("Photos/2026/202603/cam/IMG_0500.JPG", isDirectory: false)
            .path

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0500.JPG",
            sourcePath: "/source/DCIM/100/IMG_0500.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: plannedFinalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        let result = try XCTUnwrap(try StagingCommitEngine(destinationRoot: tempRoot).commit(files: [job]).first)
        XCTAssertEqual(result.disposition, .committed)
        XCTAssertEqual(
            result.finalPath,
            tempRoot.appendingPathComponent("photos/2026/202603/cam/IMG_0500.JPG", isDirectory: false).path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
    }

    func testCommitReusesExistingLowercaseMediaDirectoryConsistentlyAcrossManyFilesAndListsBucketOnce() throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("photos/2026/202603/cam", isDirectory: true),
            withIntermediateDirectories: true
        )
        // The directory listed during resolution is the parent of the
        // `Photos`/`photos` media-type folder — here that is `tempRoot` — so
        // that is the path we count.
        let bucketParent = tempRoot.standardizedFileURL.path

        var jobs: [StagingCommitEngine.FileJob] = []
        for index in 0..<16 {
            let filename = String(format: "IMG_%04d.JPG", index)
            let bytes = Data((0..<1024).map { UInt8((($0 + index) * 7) % 251) })
            let stagingPath = try writeFile(
                path: "_ingest_staging/session-many/Photos/2026/202603/cam/\(filename)",
                bytes: bytes
            )
            let plannedFinalPath = tempRoot
                .appendingPathComponent("Photos/2026/202603/cam/\(filename)", isDirectory: false)
                .path
            jobs.append(StagingCommitEngine.FileJob(
                relativePath: "DCIM/100/\(filename)",
                sourcePath: "/source/DCIM/100/\(filename)",
                stagingPath: stagingPath,
                plannedFinalPath: plannedFinalPath,
                bytesCopied: Int64(bytes.count),
                sourceHashSHA256: sha256Hex(bytes)
            ))
        }

        let countingFileManager = DirectoryListingCountingFileManager()
        let results = try StagingCommitEngine(destinationRoot: tempRoot, fileManager: countingFileManager).commit(files: jobs)

        XCTAssertEqual(results.count, jobs.count)
        for result in results {
            XCTAssertEqual(result.disposition, .committed)
            let expectedPath = tempRoot
                .appendingPathComponent("photos/2026/202603/cam/\((result.relativePath as NSString).lastPathComponent)", isDirectory: false)
                .path
            XCTAssertEqual(result.finalPath, expectedPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalPath))
        }

        XCTAssertEqual(
            countingFileManager.listingCount(forPath: bucketParent),
            1,
            "Destination bucket should be listed once for the batch, not per file"
        )
    }

    func testCommitRejectsIntermediateDestinationDirectorySymlink() throws {
        let externalRoot = tempRoot.deletingLastPathComponent()
            .appendingPathComponent("fyluro-external-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        let photosDir = libraryRoot.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let symlinkYearPath = photosDir.appendingPathComponent("2026", isDirectory: true).path
        try FileManager.default.createSymbolicLink(atPath: symlinkYearPath, withDestinationPath: externalRoot.path)

        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        let stagingPath = try writeFile(path: "library/_ingest_staging/session-sym/IMG_0700.JPG", bytes: bytes)
        let plannedFinalPath = libraryRoot
            .appendingPathComponent("Photos/2026/202603/cam/IMG_0700.JPG", isDirectory: false)
            .path

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0700.JPG",
            sourcePath: "/source/DCIM/100/IMG_0700.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: plannedFinalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        do {
            _ = try StagingCommitEngine(destinationRoot: libraryRoot).commit(files: [job])
            XCTFail("Expected commit to reject intermediate directory symlink")
        } catch let error as StagingCommitEngine.EngineError {
            guard case .runFailed(let partialResults, let remaining, let failure) = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
            XCTAssertTrue(partialResults.isEmpty)
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertEqual(failure.phase, .commit)
            XCTAssertTrue(failure.message.contains("symbolic link"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
            let externalEntries = try FileManager.default.contentsOfDirectory(atPath: externalRoot.path)
            XCTAssertTrue(externalEntries.isEmpty, "Nothing may be written outside the library root")
        }
    }

    func testCommitRejectsCaseInsensitiveMediaTypeDirectorySymlink() throws {
        let externalRoot = tempRoot.deletingLastPathComponent()
            .appendingPathComponent("fyluro-external-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let lowercaseSymlinkPath = libraryRoot.appendingPathComponent("photos", isDirectory: true).path
        try FileManager.default.createSymbolicLink(atPath: lowercaseSymlinkPath, withDestinationPath: externalRoot.path)

        let bytes = Data((0..<512).map { UInt8($0 % 241) })
        let stagingPath = try writeFile(path: "library/_ingest_staging/session-sym2/IMG_0701.JPG", bytes: bytes)
        let plannedFinalPath = libraryRoot
            .appendingPathComponent("Photos/2026/202603/cam/IMG_0701.JPG", isDirectory: false)
            .path

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0701.JPG",
            sourcePath: "/source/DCIM/100/IMG_0701.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: plannedFinalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        do {
            _ = try StagingCommitEngine(destinationRoot: libraryRoot).commit(files: [job])
            XCTFail("Expected commit to reject lowercase media-type symlink")
        } catch let error as StagingCommitEngine.EngineError {
            guard case .runFailed(_, _, let failure) = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
            XCTAssertEqual(failure.phase, .commit)
            XCTAssertTrue(failure.message.contains("symbolic link"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
            let externalEntries = try FileManager.default.contentsOfDirectory(atPath: externalRoot.path)
            XCTAssertTrue(externalEntries.isEmpty)
        }
    }

    func testCommitRejectsDanglingSymlinkAtFinalPath() throws {
        let libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        let targetDir = libraryRoot.appendingPathComponent("Photos/2026/202603/cam", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let finalPath = targetDir.appendingPathComponent("IMG_0702.JPG", isDirectory: false).path
        let outsideTarget = tempRoot.appendingPathComponent("outside-nonexistent.jpg", isDirectory: false).path
        try FileManager.default.createSymbolicLink(atPath: finalPath, withDestinationPath: outsideTarget)

        let bytes = Data((0..<256).map { UInt8($0 % 199) })
        let stagingPath = try writeFile(path: "library/_ingest_staging/session-sym3/IMG_0702.JPG", bytes: bytes)

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0702.JPG",
            sourcePath: "/source/DCIM/100/IMG_0702.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        do {
            _ = try StagingCommitEngine(destinationRoot: libraryRoot).commit(files: [job])
            XCTFail("Expected commit to reject symlink at final path")
        } catch let error as StagingCommitEngine.EngineError {
            guard case .runFailed(_, _, let failure) = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
            XCTAssertEqual(failure.phase, .commit)
            XCTAssertTrue(failure.message.contains("symbolic link"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
        }
    }

    func testCommitRejectsFinalPathOutsideDestinationRoot() throws {
        let libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        let externalRoot = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

        let bytes = Data((0..<128).map { UInt8($0 % 199) })
        let stagingPath = try writeFile(path: "library/_ingest_staging/session-escape/IMG_0703.JPG", bytes: bytes)
        let outsideFinalPath = externalRoot.appendingPathComponent("IMG_0703.JPG", isDirectory: false).path

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0703.JPG",
            sourcePath: "/source/DCIM/100/IMG_0703.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: outsideFinalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        do {
            _ = try StagingCommitEngine(destinationRoot: libraryRoot).commit(files: [job])
            XCTFail("Expected commit to reject final path outside destination root")
        } catch let error as StagingCommitEngine.EngineError {
            guard case .runFailed(_, _, let failure) = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
            XCTAssertEqual(failure.phase, .commit)
            XCTAssertTrue(failure.message.contains("outside library root"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFinalPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
        }
    }

    func testCommitTruncatesStemAndUsesUntruncatedBaseFor255ByteCollisionsOnAPFS() throws {
        let libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let ascii255Name = "\(String(repeating: "a", count: 251)).JPG"
        let utf8_255Name = "\(String(repeating: "📷", count: 62))e\u{0301}.JPG"
        XCTAssertEqual(ascii255Name.utf8.count, 255)
        XCTAssertEqual(utf8_255Name.utf8.count, 255)

        let existingBaseBytes = Data("existing-base".utf8)
        let existingCollision1Bytes = Data("existing-collision-1".utf8)
        let incomingAsciiBytes = Data("incoming-ascii-new".utf8)
        let incomingUtf8Bytes = Data("incoming-utf8-new".utf8)

        let plannedAscii1Name = CollisionFilenameBuilder.filenameByAppendingCollisionSuffix(to: ascii255Name, suffix: 1)
        let expectedAscii2Name = CollisionFilenameBuilder.filenameByAppendingCollisionSuffix(to: ascii255Name, suffix: 2)
        let plannedUtf8_1Name = CollisionFilenameBuilder.filenameByAppendingCollisionSuffix(to: utf8_255Name, suffix: 1)
        let expectedUtf8_2Name = CollisionFilenameBuilder.filenameByAppendingCollisionSuffix(to: utf8_255Name, suffix: 2)

        _ = try writeFile(path: "library/2026/\(ascii255Name)", bytes: existingBaseBytes)
        _ = try writeFile(path: "library/2026/\(plannedAscii1Name)", bytes: existingCollision1Bytes)
        _ = try writeFile(path: "library/2026/\(utf8_255Name)", bytes: existingBaseBytes)
        _ = try writeFile(path: "library/2026/\(plannedUtf8_1Name)", bytes: existingCollision1Bytes)

        let stagingAscii = try writeFile(path: "library/_ingest_staging/session-255/1.JPG", bytes: incomingAsciiBytes)
        let stagingUtf8 = try writeFile(path: "library/_ingest_staging/session-255/2.JPG", bytes: incomingUtf8Bytes)

        let asciiJob = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/\(ascii255Name)",
            sourcePath: "/source/DCIM/100/\(ascii255Name)",
            stagingPath: stagingAscii,
            plannedFinalPath: libraryRoot.appendingPathComponent("2026/\(plannedAscii1Name)").path,
            plannedCollisionSuffix: 1,
            bytesCopied: Int64(incomingAsciiBytes.count),
            sourceHashSHA256: sha256Hex(incomingAsciiBytes)
        )
        let utf8Job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/\(utf8_255Name)",
            sourcePath: "/source/DCIM/100/\(utf8_255Name)",
            stagingPath: stagingUtf8,
            plannedFinalPath: libraryRoot.appendingPathComponent("2026/\(plannedUtf8_1Name)").path,
            plannedCollisionSuffix: 1,
            bytesCopied: Int64(incomingUtf8Bytes.count),
            sourceHashSHA256: sha256Hex(incomingUtf8Bytes)
        )

        let results = try StagingCommitEngine(destinationRoot: libraryRoot).commit(files: [asciiJob, utf8Job])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].disposition, .committed)
        XCTAssertEqual(results[1].disposition, .committed)

        let expectedAscii2Path = libraryRoot.appendingPathComponent("2026/\(expectedAscii2Name)").path
        let expectedUtf8_2Path = libraryRoot.appendingPathComponent("2026/\(expectedUtf8_2Name)").path
        XCTAssertEqual((expectedAscii2Path as NSString).lastPathComponent.utf8.count, 255)
        XCTAssertLessThanOrEqual((expectedUtf8_2Path as NSString).lastPathComponent.utf8.count, 255)
        XCTAssertEqual(results[0].finalPath, expectedAscii2Path)
        XCTAssertTrue(results[0].collisionResolved)
        XCTAssertEqual(results[0].collisionSuffix, 2)
        XCTAssertEqual(results[1].finalPath, expectedUtf8_2Path)
        XCTAssertTrue(results[1].collisionResolved)
        XCTAssertEqual(results[1].collisionSuffix, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedAscii2Path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedUtf8_2Path))
    }

    func testCommitDetectsDuplicateAgainstUntruncatedBaseWhenPlannedWithTruncatedCollisionSuffix() throws {
        let libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let ascii254Name = "\(String(repeating: "c", count: 250)).JPG"
        XCTAssertEqual(ascii254Name.utf8.count, 254)

        let bytes = Data("identical-254-byte-photo".utf8)
        _ = try writeFile(path: "library/2026/\(ascii254Name)", bytes: bytes)
        let stagingPath = try writeFile(path: "library/_ingest_staging/session-254-dup/1.JPG", bytes: bytes)

        let planned1Name = CollisionFilenameBuilder.filenameByAppendingCollisionSuffix(to: ascii254Name, suffix: 1)
        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/\(ascii254Name)",
            sourcePath: "/source/DCIM/100/\(ascii254Name)",
            stagingPath: stagingPath,
            plannedFinalPath: libraryRoot.appendingPathComponent("2026/\(planned1Name)").path,
            plannedCollisionSuffix: 1,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
        )

        let results = try StagingCommitEngine(destinationRoot: libraryRoot).commit(files: [job])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].disposition, .duplicateNotCopied)
        XCTAssertEqual(results[0].finalPath, libraryRoot.appendingPathComponent("2026/\(ascii254Name)").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
    }

    @discardableResult
    private func writeFile(path: String, bytes: Data) throws -> String {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try bytes.write(to: fileURL)
        return fileURL.path
    }

    private func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { rawBuffer in
            _ = CC_SHA256(rawBuffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class DirectoryListingCountingFileManager: FileManager {
    private var listingCounts: [String: Int] = [:]

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        listingCounts[normalized, default: 0] += 1
        return try super.contentsOfDirectory(atPath: path)
    }

    func listingCount(forPath path: String) -> Int {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return listingCounts[normalized] ?? 0
    }
}

private final class SimulatedCrossVolumeMoveFileManager: FileManager {
    private var didInjectCrossVolumeError = false

    override func moveItem(atPath srcPath: String, toPath dstPath: String) throws {
        if !didInjectCrossVolumeError {
            didInjectCrossVolumeError = true
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV), userInfo: nil)
        }
        try super.moveItem(atPath: srcPath, toPath: dstPath)
    }
}
