import Dispatch
import Foundation
import XCTest
@testable import rollkeep
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CLISignalHandlerTests: XCTestCase {
    private final class SignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var firstSignals: [Int32] = []
        private(set) var secondSignals: [Int32] = []

        func recordFirst(_ sig: Int32) {
            lock.lock(); defer { lock.unlock() }
            firstSignals.append(sig)
        }

        func recordSecond(_ sig: Int32) {
            lock.lock(); defer { lock.unlock() }
            secondSignals.append(sig)
        }
    }

    func testCoordinatorInvokesFirstSignalThenSecondSignalForForcedExit() {
        let recorder = SignalRecorder()

        let coordinator = CLISignalCoordinator(
            onFirstSignal: { sig in
                recorder.recordFirst(sig)
            },
            onSecondSignal: { sig in
                recorder.recordSecond(sig)
            }
        )

        coordinator.handleSignal(SIGINT)
        coordinator.handleSignal(SIGTERM)
        coordinator.handleSignal(SIGHUP)

        XCTAssertEqual(recorder.firstSignals, [SIGINT])
        XCTAssertEqual(recorder.secondSignals, [SIGTERM, SIGHUP])
    }

    func testSignalNamesMapKnownTerminationSignals() {
        XCTAssertEqual(CLISignalCoordinator.signalName(SIGINT), "SIGINT")
        XCTAssertEqual(CLISignalCoordinator.signalName(SIGTERM), "SIGTERM")
        XCTAssertEqual(CLISignalCoordinator.signalName(SIGHUP), "SIGHUP")
    }

    func testSignalMonitorStartsAndStopsWithoutLeakingHandlers() {
        let monitor = CLISignalMonitor()
        monitor.start(signals: [SIGUSR1]) { _ in }
        monitor.stop()
    }
}
