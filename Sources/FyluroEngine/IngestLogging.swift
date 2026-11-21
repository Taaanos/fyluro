import Foundation

public protocol IngestLogging {
    func debug(_ message: String, metadata: [String: String])
    func info(_ message: String, metadata: [String: String])
    func warn(_ message: String, metadata: [String: String])
    func error(_ message: String, metadata: [String: String])
}

public extension IngestLogging {
    func debug(_ message: String) { debug(message, metadata: [:]) }
    func info(_ message: String) { info(message, metadata: [:]) }
    func warn(_ message: String) { warn(message, metadata: [:]) }
    func error(_ message: String) { error(message, metadata: [:]) }
}

public struct NoopIngestLogger: IngestLogging {
    public init() {}
    public func debug(_ message: String, metadata: [String: String]) {}
    public func info(_ message: String, metadata: [String: String]) {}
    public func warn(_ message: String, metadata: [String: String]) {}
    public func error(_ message: String, metadata: [String: String]) {}
}
