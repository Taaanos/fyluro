import Foundation
import XCTest
@testable import fyluro

final class VolumeInspectorTests: XCTestCase {
    private var tempVolumesRoot: URL!

    override func setUpWithError() throws {
        tempVolumesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-volumes-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempVolumesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempVolumesRoot {
            try? FileManager.default.removeItem(at: tempVolumesRoot)
        }
    }

    func testMountedVolumesCapturesDCIMAndRemovableHint() throws {
        try createVolume(name: "CARD_A", hasDCIM: true)
        try createVolume(name: "ARCHIVE", hasDCIM: false)

        let inspector = VolumeInspector(
            volumesRoot: tempVolumesRoot,
            removableHintProvider: { url in
                url.lastPathComponent == "CARD_A" ? true : false
            }
        )

        let mounted = inspector.mountedVolumes()
        XCTAssertEqual(mounted.count, 2)
        XCTAssertEqual(mounted[0].path, tempVolumesRoot.appendingPathComponent("ARCHIVE", isDirectory: true).path)
        XCTAssertEqual(mounted[0].hasDCIM, false)
        XCTAssertEqual(mounted[0].isRemovable, false)
        XCTAssertEqual(mounted[1].path, tempVolumesRoot.appendingPathComponent("CARD_A", isDirectory: true).path)
        XCTAssertEqual(mounted[1].hasDCIM, true)
        XCTAssertEqual(mounted[1].isRemovable, true)
    }

    func testLikelyCardVolumesUsesDCIMAndRemovableHeuristics() throws {
        try createVolume(name: "LIKELY_A", hasDCIM: true)
        try createVolume(name: "LIKELY_B", hasDCIM: false)
        try createVolume(name: "IGNORE_ME", hasDCIM: false)

        let inspector = VolumeInspector(
            volumesRoot: tempVolumesRoot,
            removableHintProvider: { url in
                switch url.lastPathComponent {
                case "LIKELY_A":
                    return true
                case "LIKELY_B":
                    return true
                default:
                    return false
                }
            }
        )

        let likely = inspector.likelyCardVolumes().map(\.path)
        XCTAssertEqual(likely, [
            tempVolumesRoot.appendingPathComponent("LIKELY_A", isDirectory: true).path,
            tempVolumesRoot.appendingPathComponent("LIKELY_B", isDirectory: true).path,
        ])
    }

    private func createVolume(name: String, hasDCIM: Bool) throws {
        let volumeURL = tempVolumesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
        if hasDCIM {
            try FileManager.default.createDirectory(
                at: volumeURL.appendingPathComponent("DCIM", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
