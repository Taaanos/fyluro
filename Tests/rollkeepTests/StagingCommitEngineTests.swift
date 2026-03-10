import CommonCrypto
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import rollkeep

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

        let job = StagingCommitEngine.FileJob(
            relativePath: "DCIM/100/IMG_0001.JPG",
            sourcePath: "/source/DCIM/100/IMG_0001.JPG",
            stagingPath: stagingPath,
            plannedFinalPath: finalPath,
            bytesCopied: Int64(bytes.count),
            sourceHashSHA256: sha256Hex(bytes)
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
