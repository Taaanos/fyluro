import Foundation

/// Structured logging sink for the ingest engine. The engine emits log events
/// through this protocol so the concrete renderer (the CLI's stdout
/// `StructuredLogger`, or a no-op / UI logger in the app) stays outside the
/// engine. Keeping the call sites in the engine preserves the exact event
/// stream regardless of who renders it.
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

/// Logger that discards everything. Useful for callers that do not need the
/// structured log stream (for example, tests, or UI consumers that observe the
/// receipt/events instead).
public struct NoopIngestLogger: IngestLogging {
    public init() {}
    public func debug(_ message: String, metadata: [String: String]) {}
    public func info(_ message: String, metadata: [String: String]) {}
    public func warn(_ message: String, metadata: [String: String]) {}
    public func error(_ message: String, metadata: [String: String]) {}
}
