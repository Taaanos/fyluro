import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Coordinates first-signal cooperative cancellation and second-signal forced exit.
final class CLISignalCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var signalCount = 0
    private let onFirstSignal: @Sendable (Int32) -> Void
    private let onSecondSignal: @Sendable (Int32) -> Void

    init(
        onFirstSignal: @escaping @Sendable (Int32) -> Void,
        onSecondSignal: @escaping @Sendable (Int32) -> Void
    ) {
        self.onFirstSignal = onFirstSignal
        self.onSecondSignal = onSecondSignal
    }

    func handleSignal(_ signalNumber: Int32) {
        let count: Int
        lock.lock()
        signalCount += 1
        count = signalCount
        lock.unlock()

        if count == 1 {
            onFirstSignal(signalNumber)
        } else {
            onSecondSignal(signalNumber)
        }
    }

    static func signalName(_ signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGINT:
            return "SIGINT"
        case SIGTERM:
            return "SIGTERM"
        case SIGHUP:
            return "SIGHUP"
        default:
            return "signal(\(signalNumber))"
        }
    }
}

/// Installs DispatchSource signal monitors for SIGINT, SIGTERM, and SIGHUP.
final class CLISignalMonitor {
    static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let queue = DispatchQueue(label: "rollkeep.cli.signals")
    private var sources: [(signal: Int32, source: DispatchSourceSignal)] = []

    func start(
        signals: [Int32] = CLISignalMonitor.handledSignals,
        handler: @escaping @Sendable (Int32) -> Void
    ) {
        stop()

        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                handler(sig)
            }
            source.resume()
            sources.append((sig, source))
        }
    }

    func stop() {
        for (sig, source) in sources {
            source.cancel()
            signal(sig, SIG_DFL)
        }
        sources.removeAll()
    }

    deinit {
        stop()
    }
}
