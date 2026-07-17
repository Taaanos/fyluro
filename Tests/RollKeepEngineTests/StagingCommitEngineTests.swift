import CommonCrypto
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RollKeepEngine

final class StagingCommitEngineTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-commit-engine-tests-\(UUID().uuidString.lowercased())"
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

        let result = try XCTUnwrap(try StagingCommitEngine().commit(files: [job]).first)
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

        let result = try XCTUnwrap(try StagingCommitEngine().commit(files: [job]).first)
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

        let result = try XCTUnwrap(try StagingCommitEngine().commit(files: [job]).first)
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

        let result = try XCTUnwrap(try StagingCommitEngine().commit(files: [job]).first)
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
            _ = try StagingCommitEngine().commit(files: jobs)
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
            try StagingCommitEngine(fileManager: simulatedFileManager).commit(files: [job]).first
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
            _ = try StagingCommitEngine(onBeforeMove: { _, _ in
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

        let result = try XCTUnwrap(try StagingCommitEngine().commit(files: [job]).first)
        XCTAssertEqual(result.disposition, .committed)
        XCTAssertEqual(
            result.finalPath,
            tempRoot.appendingPathComponent("photos/2026/202603/cam/IMG_0500.JPG", isDirectory: false).path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
    }

    func testCommitReusesExistingLowercaseMediaDirectoryConsistentlyAcrossManyFilesAndListsBucketOnce() throws {
        // Pre-existing lowercase `photos` bucket forces a non-canonical casing
        // that resolution must reproduce for every file in the batch.
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
        let results = try StagingCommitEngine(fileManager: countingFileManager).commit(files: jobs)

        XCTAssertEqual(results.count, jobs.count)
        for result in results {
            XCTAssertEqual(result.disposition, .committed)
            let expectedPath = tempRoot
                .appendingPathComponent("photos/2026/202603/cam/\((result.relativePath as NSString).lastPathComponent)", isDirectory: false)
                .path
            XCTAssertEqual(result.finalPath, expectedPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalPath))
        }

        // The whole point of the memo: the destination bucket is listed exactly
        // once for the entire batch, not once per file.
        XCTAssertEqual(
            countingFileManager.listingCount(forPath: bucketParent),
            1,
            "Destination bucket should be listed once for the batch, not per file"
        )
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
