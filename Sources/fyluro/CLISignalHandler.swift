import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CLISignalCoordinator: @unchecked Sendable {
    private enum SignalState {
        case idle
        case cancelling
        case forcedExit
    }

    private let lock = NSLock()
    private var state: SignalState = .idle
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
        let isFirstSignal: Bool
        lock.lock()
        switch state {
        case .idle:
            state = .cancelling
            isFirstSignal = true
        case .cancelling, .forcedExit:
            state = .forcedExit
            isFirstSignal = false
        }
        lock.unlock()

        if isFirstSignal {
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

final class CLISignalMonitor {
    static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let queue = DispatchQueue(label: "fyluro.cli.signals")
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
