import Foundation
import XCTest
@testable import FyluroCore

/// Synthetic-byte edge-case coverage for the TS/PAT/PMT/PES demux layer,
/// complementing `M2TSCameraMetadataExtractorCorpusTests`'s real-file
/// end-to-end validation (which is where the actual PMT `program_info_length`
/// offset bug this file's happy-path test guards against was originally
/// found and fixed).
final class M2TSCameraMetadataExtractorTests: XCTestCase {
    private var tempDirectory: URL!
    private let extractor = M2TSCameraMetadataExtractor()

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m2ts-extractor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testResolvesMakeFromSyntheticPlainTSStream() throws {
        let pat = patPacket(pmtPID: 0x0100)
        let pmt = pmtPacket(streamType: 0x1B, elementaryPID: 0x0101)
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0, 0]) // Canon
        let sei = nalUnit(type: 0x06, rbsp: seiTypeSizePayload(type: 5, payload: mdpmUUIDMarker + [1] + mdpm))
        let video = tsPacket(pid: 0x0101, pusi: true, payload: pesHeader() + sei)

        let fileURL = try writeFile(pat + pmt + video, name: "sample.mts")

        XCTAssertEqual(extractor.identity(for: fileURL)?.make, "Canon")
    }

    func testDetects192ByteM2TSPacketsWithTimecodePrefix() throws {
        let timecode: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        let pat = timecode + patPacket(pmtPID: 0x0100)
        let pmt = timecode + pmtPacket(streamType: 0x1B, elementaryPID: 0x0101)
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x01, 0x08, 0, 0]) // Sony
        let sei = nalUnit(type: 0x06, rbsp: seiTypeSizePayload(type: 5, payload: mdpmUUIDMarker + [1] + mdpm))
        let video = timecode + tsPacket(pid: 0x0101, pusi: true, payload: pesHeader() + sei)

        let fileURL = try writeFile(pat + pmt + video, name: "sample.m2ts")

        XCTAssertEqual(extractor.identity(for: fileURL)?.make, "Sony")
    }

    func testAccumulatesSEISplitAcrossContinuationPacket() throws {
        let pat = patPacket(pmtPID: 0x0100)
        let pmt = pmtPacket(streamType: 0x1B, elementaryPID: 0x0101)
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x11, 0x04, 0, 0]) // JVC
        let sei = nalUnit(type: 0x06, rbsp: seiTypeSizePayload(type: 5, payload: mdpmUUIDMarker + [1] + mdpm))
        let esData = pesHeader() + sei
        // Split the elementary stream data across two TS packets: PUSI
        // packet gets the PES header + first half, a continuation
        // (PUSI=false) packet carries the rest.
        let splitPoint = esData.count / 2
        let first = tsPacket(pid: 0x0101, pusi: true, payload: Array(esData[0..<splitPoint]))
        let second = tsPacket(pid: 0x0101, pusi: false, payload: Array(esData[splitPoint...]))

        let fileURL = try writeFile(pat + pmt + first + second, name: "sample.mts")

        XCTAssertEqual(extractor.identity(for: fileURL)?.make, "JVC")
    }

    func testReturnsNilWhenPMTHasNoH264Stream() throws {
        let pat = patPacket(pmtPID: 0x0100)
        // AC-3 audio (0x81) only, no video stream.
        let pmt = pmtPacket(streamType: 0x81, elementaryPID: 0x0101)

        let fileURL = try writeFile(pat + pmt, name: "sample.mts")

        XCTAssertNil(extractor.identity(for: fileURL))
    }

    func testReturnsNilForBadSyncByte() throws {
        var corrupted = patPacket(pmtPID: 0x0100)
        corrupted[0] = 0x00 // corrupt the sync byte
        let fileURL = try writeFile(corrupted + Data(repeating: 0xFF, count: 400), name: "sample.mts")

        XCTAssertNil(extractor.identity(for: fileURL))
    }

    func testReturnsNilForTruncatedFile() throws {
        let fileURL = try writeFile(Array("not a transport stream".utf8), name: "sample.mts")

        XCTAssertNil(extractor.identity(for: fileURL))
    }

    func testReturnsNilForNonexistentFile() {
        let fileURL = tempDirectory.appendingPathComponent("missing.mts")

        XCTAssertNil(extractor.identity(for: fileURL))
    }

    // MARK: - Synthetic TS packet builders

    private let mdpmUUIDMarker: [UInt8] = [
        0x17, 0xEE, 0x8C, 0x60, 0xF8, 0x4D, 0x11, 0xD9,
        0x8C, 0xD6, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
    ] + Array("MDPM".utf8)

    private func mdpmEntry(tag: UInt8, value: [UInt8]) -> [UInt8] {
        [tag] + value
    }

    private func seiTypeSizePayload(type: Int, payload: [UInt8]) -> [UInt8] {
        [UInt8(type)] + [UInt8(payload.count)] + payload // (kept < 255 in all these tests, no continuation needed)
    }

    private func nalUnit(type: UInt8, rbsp: [UInt8]) -> [UInt8] {
        [0, 0, 1, type] + rbsp
    }

    private func pesHeader(streamID: UInt8 = 0xE0) -> [UInt8] {
        [0x00, 0x00, 0x01, streamID, 0x00, 0x00, 0x80, 0x00, 0x00] // pes_packet_length=0, flags=0x80, header_data_length=0
    }

    /// One 188-byte TS packet: 4-byte header + `payload`, padded to exactly
    /// 188 bytes via a real adaptation field (length byte + flags byte +
    /// 0xFF stuffing) when `payload` is short, not raw trailing bytes --
    /// stuffing inside the payload region itself would corrupt a
    /// continuation packet's contribution to the elementary stream (there is
    /// no length field bounding how much of *that* payload is "real"; the
    /// parser appends all of it). This mirrors how real encoders pad and
    /// exactly matches what `parsePacketHeader`'s adaptation-field skip
    /// already handles.
    private func tsPacket(pid: UInt16, pusi: Bool, payload: [UInt8], continuityCounter: UInt8 = 0) -> Data {
        precondition(payload.count <= 184, "payload must fit in one TS packet")
        var bytes: [UInt8] = [0x47]
        bytes.append(UInt8((pusi ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)))
        bytes.append(UInt8(pid & 0xFF))

        let stuffingNeeded = 184 - payload.count
        if stuffingNeeded == 0 {
            bytes.append(0x10 | (continuityCounter & 0x0F)) // payload only, no adaptation field
            bytes += payload
        } else {
            bytes.append(0x30 | (continuityCounter & 0x0F)) // adaptation field + payload
            let adaptationFieldLength = stuffingNeeded - 1 // the length byte itself doesn't count
            bytes.append(UInt8(adaptationFieldLength))
            if adaptationFieldLength > 0 {
                bytes.append(0x00) // flags byte: no PCR/OPCR/splice/private data
                bytes += Array(repeating: UInt8(0xFF), count: adaptationFieldLength - 1)
            }
            bytes += payload
        }
        return Data(bytes)
    }

    private func patPacket(pmtPID: UInt16, programNumber: UInt16 = 1) -> Data {
        var section: [UInt8] = [0x00] // table_id (PAT)
        var body: [UInt8] = []
        body += [UInt8(programNumber >> 8), UInt8(programNumber & 0xFF)]
        body += [UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)]
        // +5 = transport_stream_id(2) + reserved/version/current_next(1) +
        // section_number(1) + last_section_number(1); +4 = trailing
        // (unchecked) CRC -- section_length covers everything after its own
        // field, through and including the CRC.
        let sectionLength = body.count + 5 + 4
        section += [UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)), UInt8(sectionLength & 0xFF)]
        section += [0x00, 0x01] // transport_stream_id
        section += [0xC1, 0x00, 0x00] // version/current_next, section_number, last_section_number
        section += body
        section += [0, 0, 0, 0] // unchecked CRC
        let payload: [UInt8] = [0x00] + section // pointer_field = 0
        return tsPacket(pid: 0, pusi: true, payload: payload)
    }

    private func pmtPacket(streamType: UInt8, elementaryPID: UInt16, programNumber: UInt16 = 1) -> Data {
        var section: [UInt8] = [0x02] // table_id (PMT)
        var body: [UInt8] = []
        body += [0xE0, 0x00] // pcr_pid (unused by our parser)
        body += [0xF0, 0x00] // program_info_length = 0
        body += [streamType, UInt8(0xE0 | (elementaryPID >> 8)), UInt8(elementaryPID & 0xFF), 0xF0, 0x00] // one stream entry
        let sectionLength = body.count + 5 + 4 // + program_number/version/section fields (5) + CRC(4)
        section += [UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)), UInt8(sectionLength & 0xFF)]
        section += [UInt8(programNumber >> 8), UInt8(programNumber & 0xFF)]
        section += [0xC1, 0x00, 0x00]
        section += body
        section += [0, 0, 0, 0]
        let payload: [UInt8] = [0x00] + section
        return tsPacket(pid: 0x0100, pusi: true, payload: payload)
    }

    private func writeFile(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeFile(_ bytes: [UInt8], name: String) throws -> URL {
        try writeFile(Data(bytes), name: name)
    }
}
