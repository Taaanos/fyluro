import Foundation
import XCTest
@testable import RollKeepCore

final class AVFoundationAudioMetadataExtractorTests: XCTestCase {
    private static let fixturesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Tests/TestingDirs", isDirectory: true)

    func testExtractFallsBackToMtimeWhenNoEmbeddedCreationDateIsReadable() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVFoundationAudioMetadataExtractorTests-\(UUID().uuidString).wav")
        try Data("not a real audio container".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fallbackMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = AVFoundationAudioMetadataExtractor().extract(from: tempURL, fallbackMtime: fallbackMtime)

        XCTAssertEqual(metadata.captureDateTime, fallbackMtime)
        XCTAssertEqual(metadata.captureDateSource, .mtimeFallback)
        XCTAssertTrue(metadata.usedFallback)
    }

    /// Real-fixture regression check: the iPhone-recording `.m4a` fixture
    /// (see `scripts/build-e2e-fixtures.py`) carries a genuine embedded
    /// `creation_time`/`Create Date` MP4 atom, unlike the DJI Pocket 3 `.WAV`
    /// sidecar which has none -- confirmed via exiftool/ffprobe during
    /// design. This locks in that AVFoundation reads it the same way.
    func testExtractReadsEmbeddedCreationTimeFromRealIPhoneRecordingFixture() throws {
        let fixtureURL = Self.fixturesRoot
            .appendingPathComponent("iphone recordings/iphone recording.m4a", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Local fixture not present: \(fixtureURL.path)")
        }

        let fallbackMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = AVFoundationAudioMetadataExtractor().extract(from: fixtureURL, fallbackMtime: fallbackMtime)

        // Cross-checked against `ffprobe`/`exiftool`, both of which read this
        // fixture's embedded moov/mvhd creation_time as 2026-07-16T05:48:57Z.
        var expectedComponents = DateComponents()
        expectedComponents.year = 2026
        expectedComponents.month = 7
        expectedComponents.day = 16
        expectedComponents.hour = 5
        expectedComponents.minute = 48
        expectedComponents.second = 57
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let expectedDate = try XCTUnwrap(utcCalendar.date(from: expectedComponents))

        XCTAssertEqual(metadata.captureDateSource, .creationTime)
        XCTAssertFalse(metadata.usedFallback)
        XCTAssertEqual(metadata.captureDateTime, expectedDate)
    }

    /// Real-fixture regression check: the DJI Pocket 3 `.WAV` companion has
    /// no embedded creation-time atom of its own -- association with its
    /// paired video's capture date happens via the sidecar mechanism, not
    /// this extractor (which only runs for standalone audio candidates).
    func testExtractFallsBackToMtimeForRealPocket3WAVFixture() throws {
        let fixtureURL = Self.fixturesRoot
            .appendingPathComponent("pocket-3/DJI_20240126093104_0012_D.WAV", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Local fixture not present: \(fixtureURL.path)")
        }

        let fallbackMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = AVFoundationAudioMetadataExtractor().extract(from: fixtureURL, fallbackMtime: fallbackMtime)

        XCTAssertEqual(metadata.captureDateSource, .mtimeFallback)
        XCTAssertTrue(metadata.usedFallback)
        XCTAssertEqual(metadata.captureDateTime, fallbackMtime)
    }
}
