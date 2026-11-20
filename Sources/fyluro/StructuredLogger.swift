import Foundation
import FyluroCore
import FyluroEngine

struct StructuredLogger: IngestLogging {
    enum Level: String {
        case debug
        case info
        case warn
        case error
    }

    let verbose: Bool

    func debug(_ message: String, metadata: [String: String] = [:]) {
        guard verbose else { return }
        log(.debug, message: message, metadata: metadata)
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        log(.info, message: message, metadata: metadata)
    }

    func warn(_ message: String, metadata: [String: String] = [:]) {
        log(.warn, message: message, metadata: metadata)
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        log(.error, message: message, metadata: metadata)
    }

    private func log(_ level: Level, message: String, metadata: [String: String]) {
        let safeMessage = TerminalTextSanitizer.sanitize(message)
        var payload: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "message": safeMessage,
            "component": "fyluro-cli",
        ]

        for (key, value) in metadata {
            payload[TerminalTextSanitizer.sanitize(key)] = TerminalTextSanitizer.sanitize(value)
        }

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            return
        }

        print("{\"level\":\"\(level.rawValue)\",\"message\":\"\(safeMessage)\"}")
    }
}
