import Foundation
import XCTest
@testable import RollKeepCore

final class ISOBMFFBoxWalkerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isobmff-box-walker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReadsSimpleTopLevelBoxes() throws {
        let box1 = box(size: 8, type: "ftyp")
        let box2 = box(size: 12, type: "free", payload: Data(repeating: 0x41, count: 4))
        let handle = try makeHandle(box1 + box2)
        defer { try? handle.close() }

        let boxes = ISOBMFFBoxWalker().readBoxes(in: handle, range: 0..<UInt64(box1.count + box2.count))

        XCTAssertEqual(boxes, [
            ISOBMFFBox(type: "ftyp", payloadOffset: 8, payloadSize: 0),
            ISOBMFFBox(type: "free", payloadOffset: 16, payloadSize: 4),
        ])
    }

    func testHandlesExtendedSize64Bit() throws {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) })
        data.append("mdat".data(using: .ascii)!)
        let extendedSize: UInt64 = 16 + 20
        data.append(contentsOf: withUnsafeBytes(of: extendedSize.bigEndian) { Array($0) })
        data.append(Data(repeating: 0x00, count: 20))
        let handle = try makeHandle(data)
        defer { try? handle.close() }

        let boxes = ISOBMFFBoxWalker().readBoxes(in: handle, range: 0..<UInt64(data.count))

        XCTAssertEqual(boxes, [ISOBMFFBox(type: "mdat", payloadOffset: 16, payloadSize: 20)])
    }

    func testHandlesSizeZeroRunsToEndOfRange() throws {
        let data = box(size: 0, type: "mdat", payload: Data(repeating: 0x00, count: 30))
        let handle = try makeHandle(data)
        defer { try? handle.close() }

        let boxes = ISOBMFFBoxWalker().readBoxes(in: handle, range: 0..<UInt64(data.count))

        XCTAssertEqual(boxes, [ISOBMFFBox(type: "mdat", payloadOffset: 8, payloadSize: 30)])
    }

    func testGracefullyStopsOnTruncatedTrailingHeader() throws {
        let full = box(size: 8, type: "ftyp")
        let data = full + Data([0x00, 0x00, 0x00])
        let handle = try makeHandle(data)
        defer { try? handle.close() }

        let boxes = ISOBMFFBoxWalker().readBoxes(in: handle, range: 0..<UInt64(data.count))

        XCTAssertEqual(boxes, [ISOBMFFBox(type: "ftyp", payloadOffset: 8, payloadSize: 0)])
    }

    /// Reproduces the DJI-fixture trailing zero-padding case: after the last
    /// real box, leftover padding decodes as a "box" whose declared size
    /// vastly exceeds the remaining bytes. The walker must stop, not guess.
    func testGracefullyStopsOnBogusOversizedDeclaredSize() throws {
        let real = box(size: 8, type: "free")
        var bogus = Data()
        bogus.append(contentsOf: withUnsafeBytes(of: UInt32(1_751_411_826).bigEndian) { Array($0) })
        bogus.append(Data(repeating: 0x00, count: 4))
        let handle = try makeHandle(real + bogus)
        defer { try? handle.close() }

        let boxes = ISOBMFFBoxWalker().readBoxes(in: handle, range: 0..<UInt64(real.count + bogus.count))

        XCTAssertEqual(boxes, [ISOBMFFBox(type: "free", payloadOffset: 8, payloadSize: 0)])
    }

    func testReturnsEmptyForAbsentContainer() throws {
        let handle = try makeHandle(Data())
        defer { try? handle.close() }

        XCTAssertEqual(ISOBMFFBoxWalker().readBoxes(in: handle, range: 0..<0), [])
    }

    func testRecursesIntoNestedContainerViaSecondCall() throws {
        let child = box(size: 8, type: "GPMF")
        let udta = box(size: UInt32(8 + child.count), type: "udta", payload: child)
        let handle = try makeHandle(udta)
        defer { try? handle.close() }

        let walker = ISOBMFFBoxWalker()
        let topLevel = walker.readBoxes(in: handle, range: 0..<UInt64(udta.count))
        XCTAssertEqual(topLevel, [ISOBMFFBox(type: "udta", payloadOffset: 8, payloadSize: 8)])

        let udtaBox = topLevel[0]
        let children = walker.readBoxes(
            in: handle,
            range: udtaBox.payloadOffset..<(udtaBox.payloadOffset + udtaBox.payloadSize)
        )
        XCTAssertEqual(children, [ISOBMFFBox(type: "GPMF", payloadOffset: 16, payloadSize: 0)])
    }

    func testReadPayloadReturnsBoundedBytes() throws {
        let payload = Data("hello vendor atom".utf8)
        let data = box(size: UInt32(8 + payload.count), type: "Xtra", payload: payload)
        let handle = try makeHandle(data)
        defer { try? handle.close() }

        let walker = ISOBMFFBoxWalker()
        let boxes = walker.readBoxes(in: handle, range: 0..<UInt64(data.count))

        XCTAssertEqual(walker.readPayload(of: boxes[0], from: handle), payload)
    }

    func testReadPayloadRespectsMaxLength() throws {
        let payload = Data(repeating: 0x2A, count: 100)
        let data = box(size: UInt32(8 + payload.count), type: "GPMF", payload: payload)
        let handle = try makeHandle(data)
        defer { try? handle.close() }

        let walker = ISOBMFFBoxWalker()
        let boxes = walker.readBoxes(in: handle, range: 0..<UInt64(data.count))

        XCTAssertEqual(walker.readPayload(of: boxes[0], from: handle, maxLength: 10)?.count, 10)
    }

    func testFirstChildNamedReturnsMatchingBox() {
        let boxes = [
            ISOBMFFBox(type: "free", payloadOffset: 0, payloadSize: 0),
            ISOBMFFBox(type: "GPMF", payloadOffset: 8, payloadSize: 4),
        ]

        XCTAssertEqual(ISOBMFFBoxWalker().firstChild(named: "GPMF", in: boxes)?.payloadOffset, 8)
        XCTAssertNil(ISOBMFFBoxWalker().firstChild(named: "Xtra", in: boxes))
    }

    // MARK: - Helpers

    private func box(size: UInt32, type: String, payload: Data = Data()) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    private func makeHandle(_ data: Data, name: String = UUID().uuidString) throws -> FileHandle {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return try FileHandle(forReadingFrom: url)
    }
}
