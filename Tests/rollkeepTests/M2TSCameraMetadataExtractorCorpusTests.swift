import Foundation
import XCTest
@testable import RollKeepCore

/// Validates `M2TSCameraMetadataExtractor` against exiftool's own bundled
/// `t/images/M2TS.mts` corpus file (see docs/guides/exiftool-sync.md) -- the only
/// real AVCHD/M2TS sample available, so this is the primary correctness
/// check for the TS/PES/SEI/MDPM chain end to end, complementing the
/// synthetic unit tests for each layer individually.
final class M2TSCameraMetadataExtractorCorpusTests: XCTestCase {
    private static var exiftoolCheckoutURL: URL? {
        guard let override = ProcessInfo.processInfo.environment["ROLLKEEP_EXIFTOOL_CHECKOUT"], !override.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    func testResolvesCanonMakeFromRealCorpusFile() throws {
        guard let checkoutURL = Self.exiftoolCheckoutURL else {
            throw XCTSkip("ROLLKEEP_EXIFTOOL_CHECKOUT not set")
        }
        let fileURL = checkoutURL.appendingPathComponent("t/images/M2TS.mts")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("exiftool checkout not present at \(checkoutURL.path)")
        }

        let decoded = M2TSCameraMetadataExtractor().identity(for: fileURL)

        // Oracle (scripts/refresh-exiftool-oracle-snapshot.sh output): Make
        // "Canon", no Model -- exiftool's own H264.pm MakeModel table has no
        // usable Model field either (see its "1 => ModelIDCode ... I think
        // not" comment), so parity, not a gap, is model=nil here too.
        XCTAssertEqual(decoded?.make, "Canon")
    }
}
