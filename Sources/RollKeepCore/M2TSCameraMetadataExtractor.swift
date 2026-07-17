import Foundation

/// Resolves camera make/model for an AVCHD `.mts`/`.m2ts` file. AVFoundation
/// cannot open raw MPEG-2 Transport Stream containers for metadata, and
/// M2TS has no `udta`-equivalent box at all -- the only place camera
/// identity lives is inside the H.264 video elementary stream's own SEI NAL
/// units (see `H264SEIMDPMParser`). This does the minimal, bounded TS/PES
/// demux needed to hand that parser a contiguous elementary-stream buffer
/// (ported facts: exiftool M2TS.pm ProcessM2TS -- packet-size detection,
/// PAT -> PMT -> H.264 video PID resolution, PES header stripping). Timing
/// (PCR/duration), audio PIDs, and dashcam-specific GPS PIDs are all out of
/// scope: this only exists to find the video PID and read enough of it.
struct M2TSCameraMetadataExtractor {
    private static let standardPacketLength = 188
    private static let timecodePrefixLength = 4
    private static let programAssociationTablePID: UInt16 = 0
    private static let h264StreamType: UInt8 = 0x1B
    /// Real-world MDPM SEI data appears in the first GOP; this is a
    /// generous bound on total elementary-stream bytes collected before
    /// giving up, keeping the read cost independent of file size
    /// (RT-P0-12: never scale reads with an
    /// untrusted/attacker-influenced file's declared or actual length).
    private static let maxElementaryStreamBytes = 2 * 1024 * 1024
    /// Bounds how many TS packets we will scan looking for the video PID
    /// and enough of its data, independent of file size.
    private static let maxPacketsScanned = 20_000

    private let seiParser: H264SEIMDPMParser

    init(seiParser: H264SEIMDPMParser = H264SEIMDPMParser()) {
        self.seiParser = seiParser
    }

    func identity(for fileURL: URL) -> (make: String?, model: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let timecodePrefixLength = Self.detectTimecodePrefixLength(handle) else {
            return nil
        }
        let packetLength = Self.standardPacketLength + timecodePrefixLength

        var pmtPIDs: Set<UInt16> = []
        var videoPID: UInt16?
        var elementaryStream = Data()
        var packetIndex = 0
        var offset: UInt64 = 0

        while packetIndex < Self.maxPacketsScanned, elementaryStream.count < Self.maxElementaryStreamBytes {
            packetIndex += 1
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let rawPacket = try? handle.read(upToCount: packetLength),
                  rawPacket.count == packetLength
            else {
                break
            }
            offset += UInt64(packetLength)
            // Drop the AVCHD arrival-time prefix, if any -- everything below
            // operates on the bare 188-byte TS packet.
            let packet = timecodePrefixLength == 0
                ? rawPacket
                : rawPacket.subdata(in: (rawPacket.startIndex + timecodePrefixLength)..<rawPacket.endIndex)

            guard let header = Self.parsePacketHeader(packet) else {
                break // sync byte mismatch: stop rather than guess at resync
            }

            var payloadStart = header.tsHeaderLength
            if header.hasAdaptationField {
                guard payloadStart < packet.count else {
                    continue
                }
                let adaptationLength = Int(packet[packet.startIndex + payloadStart])
                payloadStart += 1 + adaptationLength
            }
            guard header.hasPayload, payloadStart < packet.count else {
                continue
            }
            let payload = packet.subdata(in: (packet.startIndex + payloadStart)..<packet.endIndex)

            if header.pid == Self.programAssociationTablePID {
                if let pmtPID = Self.parsePAT(payload, payloadUnitStart: header.payloadUnitStart) {
                    pmtPIDs.insert(pmtPID)
                }
            } else if pmtPIDs.contains(header.pid) {
                if let pid = Self.parsePMTForH264VideoPID(payload, payloadUnitStart: header.payloadUnitStart) {
                    videoPID = pid
                }
            } else if let videoPID, header.pid == videoPID {
                if header.payloadUnitStart, let esPayload = Self.stripPESHeader(payload) {
                    elementaryStream.append(esPayload)
                } else if !header.payloadUnitStart, !elementaryStream.isEmpty {
                    // Continuation of the current PES packet's elementary
                    // stream data -- only meaningful once a PES header has
                    // been seen at least once (guarded by the non-empty
                    // check), matching exiftool's own "must start from a
                    // payload_unit_start_indicator packet" rule.
                    elementaryStream.append(payload)
                }
            }
        }

        guard !elementaryStream.isEmpty else {
            return nil
        }
        let decoded = seiParser.parse(elementaryStream)
        return (decoded.make != nil || decoded.model != nil) ? decoded : nil
    }

    // MARK: - Packet framing

    /// AVCHD/BDAV `.m2ts` files prefix each 188-byte TS packet with a
    /// 4-byte arrival-time timecode (192-byte "M2TS" packets); plain `.ts`/
    /// some `.mts` files don't. Detected by checking for the 0x47 sync byte
    /// at both candidate strides over the first few packets. Returns the
    /// prefix length (0 or 4), not the total packet length, since every
    /// other offset in this file is expressed relative to the bare
    /// 188-byte TS packet.
    private static func detectTimecodePrefixLength(_ handle: FileHandle) -> Int? {
        guard (try? handle.seek(toOffset: 0)) != nil,
              let probe = try? handle.read(upToCount: 4 * (standardPacketLength + timecodePrefixLength)),
              probe.count >= 2 * (standardPacketLength + timecodePrefixLength)
        else {
            return nil
        }

        if isSyncByteAt(probe, offset: 0, stride: standardPacketLength, count: 3) {
            return 0
        }
        if isSyncByteAt(probe, offset: timecodePrefixLength, stride: standardPacketLength + timecodePrefixLength, count: 3) {
            return timecodePrefixLength
        }
        return nil
    }

    private static func isSyncByteAt(_ data: Data, offset: Int, stride: Int, count: Int) -> Bool {
        for i in 0..<count {
            let index = data.startIndex + offset + i * stride
            guard index < data.endIndex, data[index] == 0x47 else {
                return false
            }
        }
        return true
    }

    private struct PacketHeader {
        let pid: UInt16
        let payloadUnitStart: Bool
        let hasAdaptationField: Bool
        let hasPayload: Bool
        /// Offset of the payload area from the start of the 188-byte TS
        /// packet portion (i.e. after any 4-byte timecode prefix, which the
        /// caller has already excluded from `packet`).
        let tsHeaderLength: Int
    }

    private static func parsePacketHeader(_ packet: Data) -> PacketHeader? {
        // packet here is exactly one TS packet (timecode prefix, if any,
        // already stripped by the caller via packetLength bookkeeping --
        // see identity(for:), which reads packetLength bytes starting at
        // the TS sync byte itself).
        guard packet.count >= 4, packet[packet.startIndex] == 0x47 else {
            return nil
        }
        let b1 = packet[packet.startIndex + 1]
        let b2 = packet[packet.startIndex + 2]
        let b3 = packet[packet.startIndex + 3]

        let payloadUnitStart = (b1 & 0x40) != 0
        let pid = (UInt16(b1 & 0x1F) << 8) | UInt16(b2)
        let adaptationFieldControl = (b3 & 0x30) >> 4

        return PacketHeader(
            pid: pid,
            payloadUnitStart: payloadUnitStart,
            hasAdaptationField: adaptationFieldControl == 2 || adaptationFieldControl == 3,
            hasPayload: adaptationFieldControl == 1 || adaptationFieldControl == 3,
            tsHeaderLength: 4
        )
    }

    // MARK: - PAT / PMT (single-packet sections only -- MDPM cards never need multi-packet PSI)

    /// Parses a Program Association Table packet and returns the first
    /// Program Map Table PID found. Ignores the "pointer field" spanning
    /// multiple packets; real AVCHD PAT/PMT sections are tiny and complete
    /// in one packet.
    private static func parsePAT(_ payload: Data, payloadUnitStart: Bool) -> UInt16? {
        guard payloadUnitStart, payload.count > 1 else {
            return nil
        }
        let pointerField = Int(payload[payload.startIndex])
        var pos = payload.startIndex + 1 + pointerField
        guard pos + 8 <= payload.endIndex, payload[pos] == 0x00 else {
            return nil // table_id 0x00 = PAT
        }
        let sectionLength = Int(UInt16(payload[pos + 1] & 0x0F) << 8 | UInt16(payload[pos + 2]))
        let sectionEnd = pos + 3 + sectionLength - 4 // exclude trailing 4-byte CRC
        pos += 8 // skip table_id..last_section_number
        guard sectionEnd <= payload.endIndex else {
            return nil
        }
        while pos + 4 <= sectionEnd {
            let programNumber = UInt16(payload[pos]) << 8 | UInt16(payload[pos + 1])
            let pmtPID = (UInt16(payload[pos + 2] & 0x1F) << 8) | UInt16(payload[pos + 3])
            pos += 4
            if programNumber != 0 { // program_number 0 is the Network PID entry, not a PMT
                return pmtPID
            }
        }
        return nil
    }

    private static func parsePMTForH264VideoPID(_ payload: Data, payloadUnitStart: Bool) -> UInt16? {
        guard payloadUnitStart, payload.count > 1 else {
            return nil
        }
        let pointerField = Int(payload[payload.startIndex])
        var pos = payload.startIndex + 1 + pointerField
        guard pos + 12 <= payload.endIndex, payload[pos] == 0x02 else {
            return nil // table_id 0x02 = PMT
        }
        let sectionLength = Int(UInt16(payload[pos + 1] & 0x0F) << 8 | UInt16(payload[pos + 2]))
        let sectionEnd = pos + 3 + sectionLength - 4
        guard sectionEnd <= payload.endIndex else {
            return nil
        }
        pos += 8 // table_id, section_length(2), program_number(2), version/section numbers(3) -- lands on pcr_pid
        // pcr_pid itself (payload[pos..<pos+2]) is unused for our purposes;
        // program_info_length is the NEXT two bytes, not these ones.
        let programInfoLength = Int(UInt16(payload[pos + 2] & 0x0F) << 8 | UInt16(payload[pos + 3]))
        pos += 4 + programInfoLength // pcr_pid(2) + program_info_length field(2) + descriptors
        guard pos <= sectionEnd else {
            return nil
        }
        while pos + 5 <= sectionEnd {
            let streamType = payload[pos]
            let elementaryPID = (UInt16(payload[pos + 1] & 0x1F) << 8) | UInt16(payload[pos + 2])
            let esInfoLength = Int(UInt16(payload[pos + 3] & 0x0F) << 8 | UInt16(payload[pos + 4]))
            pos += 5 + esInfoLength
            if streamType == h264StreamType {
                return elementaryPID
            }
        }
        return nil
    }

    // MARK: - PES header stripping

    /// Strips the PES packet header (`00 00 01`, stream ID, packet length,
    /// then flags + a variable-length header-data area) leaving raw H.264
    /// Annex-B bytes, or nil if this doesn't look like a PES start.
    private static func stripPESHeader(_ payload: Data) -> Data? {
        guard payload.count >= 9 else {
            return nil
        }
        let start = payload.startIndex
        guard payload[start] == 0, payload[start + 1] == 0, payload[start + 2] == 1 else {
            return nil
        }
        guard (payload[start + 6] & 0xC0) == 0x80 else {
            return nil // PES syntax marker bits
        }
        let headerDataLength = Int(payload[start + 8])
        let esStart = start + 9 + headerDataLength
        guard esStart <= payload.endIndex else {
            return nil
        }
        return payload.subdata(in: esStart..<payload.endIndex)
    }
}
