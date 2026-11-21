import Foundation

struct ISOBMFFBox: Equatable {
    let type: String
    let payloadOffset: UInt64
    let payloadSize: UInt64
    /// For `uuid` boxes: the 16-byte usertype GUID read from the start of the
    /// payload (nil for other box types, or when the payload is too short).
    let uuidUsertype: Data?

    init(type: String, payloadOffset: UInt64, payloadSize: UInt64, uuidUsertype: Data? = nil) {
        self.type = type
        self.payloadOffset = payloadOffset
        self.payloadSize = payloadSize
        self.uuidUsertype = uuidUsertype
    }

    /// The payload range of a `uuid` box with its usertype stripped -- the
    /// content region vendor uuid formats (Canon CR3/MP4, Garmin) are defined
    /// over. `payloadOffset + payloadSize` was already validated against the
    /// enclosing range by the walker, so this addition cannot overflow.
    var uuidContentRange: Range<UInt64>? {
        guard uuidUsertype != nil, payloadSize >= ISOBMFFBoxWalker.uuidUsertypeLength else {
            return nil
        }
        return (payloadOffset + ISOBMFFBoxWalker.uuidUsertypeLength)..<(payloadOffset + payloadSize)
    }
}

/// Reads only ISO-BMFF/QuickTime box headers (8 or 16 bytes each), seeking past
/// payload bytes without reading them. Callers recurse by calling `readBoxes`
/// again on a found child's payload range (e.g. moov -> udta, meta -> xml).
struct ISOBMFFBoxWalker {
    private static let headerSize: UInt64 = 8
    private static let extendedSizeFieldLength: UInt64 = 8
    private static let maxBoxesPerLevel = 10_000
    private static let defaultMaxPayloadReadLength: UInt64 = 1_000_000
    static let uuidUsertypeLength: UInt64 = 16

    func readBoxes(in handle: FileHandle, range: Range<UInt64>) -> [ISOBMFFBox] {
        var boxes: [ISOBMFFBox] = []
        var offset = range.lowerBound

        while offset + Self.headerSize <= range.upperBound, boxes.count < Self.maxBoxesPerLevel {
            guard let header = read(handle: handle, offset: offset, length: Self.headerSize),
                  header.count == Self.headerSize
            else {
                break
            }

            let declaredSize = UInt64(bigEndianUInt32: header.subdata(in: 0..<4))
            let type = Self.fourCC(header.subdata(in: 4..<8))

            var headerLength = Self.headerSize
            var boxSize = declaredSize

            if declaredSize == 1 {
                headerLength += Self.extendedSizeFieldLength
                guard offset + headerLength <= range.upperBound,
                      let extended = read(handle: handle, offset: offset + Self.headerSize, length: Self.extendedSizeFieldLength),
                      extended.count == Self.extendedSizeFieldLength
                else {
                    break
                }
                boxSize = extended.bigEndianUInt64
            } else if declaredSize == 0 {
                boxSize = range.upperBound - offset
            }

            // Malformed (size smaller than its own header) or truncated/oversized
            // (declared size runs past the end of this range, e.g. trailing
            // padding after the last real box) -> stop instead of guessing.
            // `boxSize` is attacker-controlled up to UInt64.max via the
            // extended-size path above, so this addition must be overflow-safe:
            // a bare `+` traps (crashes the process) on overflow instead of
            // throwing a catchable error.
            let (endOffset, overflowed) = offset.addingReportingOverflow(boxSize)
            guard boxSize >= headerLength, !overflowed, endOffset <= range.upperBound else {
                break
            }

            // uuid boxes carry a 16-byte usertype GUID at the start of the
            // payload; capture it so callers can dispatch on it (Canon
            // CR3/MP4, Garmin). One small absolute-offset read per uuid box;
            // uuid boxes are rare, so this stays within the header-only
            // I/O budget.
            var uuidUsertype: Data?
            if type == "uuid", boxSize - headerLength >= Self.uuidUsertypeLength {
                uuidUsertype = read(
                    handle: handle,
                    offset: offset + headerLength,
                    length: Self.uuidUsertypeLength
                )
            }

            boxes.append(ISOBMFFBox(
                type: type,
                payloadOffset: offset + headerLength,
                payloadSize: boxSize - headerLength,
                uuidUsertype: uuidUsertype
            ))

            offset += boxSize
        }

        return boxes
    }

    /// Reads a bounded prefix of a box's payload. `maxLength` defaults to 1MB,
    /// comfortably above the largest known vendor-metadata atom (tens of KB)
    /// but far below anything resembling real media sample data.
    func readPayload(
        of box: ISOBMFFBox,
        from handle: FileHandle,
        maxLength: UInt64 = ISOBMFFBoxWalker.defaultMaxPayloadReadLength
    ) -> Data? {
        let length = min(box.payloadSize, maxLength)
        guard length > 0 else {
            return nil
        }
        return read(handle: handle, offset: box.payloadOffset, length: length)
    }

    func firstChild(named type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        boxes.first { $0.type == type }
    }

    func firstUUIDChild(usertype: Data, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        boxes.first { $0.type == "uuid" && $0.uuidUsertype == usertype }
    }

    func readUUIDBoxContent(usertype: Data, among boxes: [ISOBMFFBox], from handle: FileHandle) -> Data? {
        guard let match = firstUUIDChild(usertype: usertype, in: boxes),
              let contentRange = match.uuidContentRange
        else {
            return nil
        }

        let contentBox = ISOBMFFBox(
            type: match.type,
            payloadOffset: contentRange.lowerBound,
            payloadSize: contentRange.upperBound - contentRange.lowerBound
        )
        return readPayload(of: contentBox, from: handle)
    }

    /// FourCC bytes decoded as Latin-1 so every byte maps to exactly one
    /// scalar -- vendor tags use 0xA9 ("©mak", "©mod", ...) which UTF-8
    /// decoding would mangle into U+FFFD, making the codes collide.
    static func fourCC(_ bytes: Data) -> String {
        String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// Walks MOV-style child boxes held fully in memory (vendor atom
    /// payloads like Nikon NCDT or the Canon uuid content, already bounded
    /// by `readPayload`). Same malformed-size rules as `readBoxes`: stop on
    /// anything that lies about its length rather than guessing.
    static func childBoxes(in data: Data) -> [(type: String, payload: Data)] {
        var children: [(type: String, payload: Data)] = []
        let bytes = data.startIndex == 0 ? data : Data(data)
        var offset = 0

        while bytes.count - offset >= 8, children.count < maxBoxesPerLevel {
            let declaredSize = Int(UInt64(bigEndianUInt32: bytes.subdata(in: offset..<(offset + 4))))
            let type = fourCC(bytes.subdata(in: (offset + 4)..<(offset + 8)))

            // In-memory vendor payloads never legitimately use the 64-bit
            // extended size (1) here; size 0 means "to end of container".
            let boxSize = declaredSize == 0 ? bytes.count - offset : declaredSize
            guard boxSize >= 8, bytes.count - offset >= boxSize else {
                break
            }

            children.append((type: type, payload: bytes.subdata(in: (offset + 8)..<(offset + boxSize))))
            offset += boxSize
        }

        return children
    }

    private func read(handle: FileHandle, offset: UInt64, length: UInt64) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              length <= UInt64(Int.max),
              let data = try? handle.read(upToCount: Int(length))
        else {
            return nil
        }
        return data
    }
}

private extension UInt64 {
    init(bigEndianUInt32 data: Data) {
        self = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

private extension Data {
    var bigEndianUInt64: UInt64 {
        reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
