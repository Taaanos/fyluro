import Foundation

public enum TerminalTextSanitizer {
    public static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isUnsafeTerminalScalar) else {
            return text
        }

        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)

        for scalar in text.unicodeScalars {
            if isUnsafeTerminalScalar(scalar) {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                let padded = hex.count < 4
                    ? String(repeating: "0", count: 4 - hex.count) + hex
                    : hex
                result += "\\u{\(padded)}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
    }

    private static func isUnsafeTerminalScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F: // C0 controls (ESC, CR, LF, TAB, BEL, BS, etc.)
            return true
        case 0x007F...0x009F: // DEL and C1 controls (including 8-bit CSI 0x9B, OSC 0x9D)
            return true
        case 0x061C,          // ARABIC LETTER MARK
             0x200E...0x200F, // LRM, RLM
             0x2028...0x2029, // LINE SEPARATOR, PARAGRAPH SEPARATOR
             0x202A...0x202E, // LRE, RLE, PDF, LRO, RLO (U+202E)
             0x2066...0x2069: // LRI, RLI, FSI, PDI
            return true
        default:
            return false
        }
    }
}
