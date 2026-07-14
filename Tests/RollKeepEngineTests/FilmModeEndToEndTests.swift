import CoreGraphics
import Foundation
import ImageIO
import RollKeepCore
import UniformTypeIdentifiers
import XCTest
@testable import RollKeepEngine

/// Exercises Film Mode through the real, full ingest pipeline (scan -> plan
/// -> copy -> verify -> commit), the same way the app runs it in-process.
/// Film Mode has no CLI surface, so this is the closest equivalent to the
/// shell-script e2e harnesses used for CLI-facing scenarios.
final class FilmModeEndToEndTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-film-mode-e2e-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testFilmModeOverridesDSLRExifAndPlacesFileByDeclaredMonthAndCameraWithoutMutatingSource() throws {
        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)

        // Simulates a digitized-film photo shot on a DSLR: real EXIF, but the
        // scan date/DSLR model, not the original film camera/shoot date.
        let sourcePhotoURL = dcim.appendingPathComponent("IMG_9001.JPG", isDirectory: false)
        try writeTinyJPEG(
            to: sourcePhotoURL,
            tiffMake: "Canon",
            tiffModel: "EOS 5D Mark IV",
            dateTimeOriginal: "2026:07:14 10:00:00"
        )
        let originalSourceData = try Data(contentsOf: sourcePhotoURL)

        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let override = FilmModeOverride(year: 1998, month: 7, camera: "Pentax K1000", filmStock: "Kodak Gold 200", iso: 200)

        let request = IngestRequest(
            sourceURL: source,
            destinationURL: dest,
            sourceResolution: "explicit",
            destinationResolution: "explicit",
            pathScheme: ImportPathScheme(
                chronologicalLayout: .yearYearMonthCompact,
                includeCameraFolder: true,
                splitPhotoCompression: false
            ),
            dryRun: false,
            writePDF: false,
            maxParallelCopies: 1,
            jsonSummaryRequested: false,
            detectTimeoutSeconds: 60,
            pickSource: false,
            pickDestination: false,
            filmModeOverride: override
        )

        let collector = CommittedPathCollector()
        let session = IngestSession(request: request, logger: NoopIngestLogger(), faultInjection: .none)
        session.eventObserver = { event in
            if case let .fileCommitted(_, finalPath) = event {
                collector.record(finalPath)
            }
        }
        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "completed")
        XCTAssertEqual(result.counts.committed, 1)

        let finalPath = try XCTUnwrap(collector.paths.first)
        XCTAssertTrue(finalPath.contains("/1998/199807/"), finalPath)
        XCTAssertTrue(finalPath.contains("/pentax-k1000/"), finalPath)

        let finalMetadata = ImageIOPhotoMetadataExtractor().extract(from: URL(fileURLWithPath: finalPath))
        XCTAssertNil(finalMetadata.cameraMake)
        XCTAssertEqual(finalMetadata.cameraModel, "Pentax K1000")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.year, .month],
            from: try XCTUnwrap(finalMetadata.captureDateTime)
        )
        XCTAssertEqual(components.year, 1998)
        XCTAssertEqual(components.month, 7)

        // The original source file must never be mutated by Film Mode.
        let sourceDataAfterRun = try Data(contentsOf: sourcePhotoURL)
        XCTAssertEqual(originalSourceData, sourceDataAfterRun)
    }

    private final class CommittedPathCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var paths: [String] = []
        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.append(path)
        }
    }

    private func writeTinyJPEG(
        to fileURL: URL,
        tiffMake: String,
        tiffModel: String,
        dateTimeOriginal: String
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "FilmModeEndToEndTests", code: 1)
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            throw NSError(domain: "FilmModeEndToEndTests", code: 2)
        }

        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: tiffMake,
                kCGImagePropertyTIFFModel as String: tiffModel,
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: dateTimeOriginal,
            ],
        ]

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "FilmModeEndToEndTests", code: 3)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "FilmModeEndToEndTests", code: 4)
        }
    }
}
