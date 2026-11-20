import FyluroCore
import XCTest

final class TerminalTextSanitizerTests: XCTestCase {
    func testPreservesPlainASCIIAndStandardUTF8() {
        let input = "/Volumes/EOS_DIGITAL/DCIM/100CANON/café_IMG_0001.jpg"
        XCTAssertEqual(TerminalTextSanitizer.sanitize(input), input)
    }

    func testEscapesC0ControlsDELAndC1Controls() {
        let input = "\u{0000}\u{0007}\u{0009}\u{000A}\u{000D}\u{001B}[31mHACKED\u{001B}[0m\u{007F}\u{009B}A"
        let expected = "\\u{0000}\\u{0007}\\u{0009}\\u{000A}\\u{000D}\\u{001B}[31mHACKED\\u{001B}[0m\\u{007F}\\u{009B}A"
        XCTAssertEqual(TerminalTextSanitizer.sanitize(input), expected)
    }

    func testEscapesBidiAndLineSeparatorControls() {
        let input = "clip_\u{202E}gpj.mp4_\u{061C}\u{200E}\u{200F}\u{2028}\u{2029}\u{202A}\u{202D}\u{2066}\u{2069}"
        let expected = "clip_\\u{202E}gpj.mp4_\\u{061C}\\u{200E}\\u{200F}\\u{2028}\\u{2029}\\u{202A}\\u{202D}\\u{2066}\\u{2069}"
        XCTAssertEqual(TerminalTextSanitizer.sanitize(input), expected)
    }
}
