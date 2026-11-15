import Foundation
import IOKit.pwr_mgt

/// Represents an active macOS idle-sleep power assertion.
protocol IdleSleepAssertionToken: Sendable {
    /// Releases the power assertion. Safe to call more than once.
    func release()
}

/// Acquires a macOS idle-sleep power assertion for an ingest session.
protocol IdleSleepAssertionManaging: Sendable {
    func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)?
}

/// Holds an `IOPMAssertionID` preventing idle system sleep until released.
final class SystemIdleSleepAssertionToken: IdleSleepAssertionToken, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    init(assertionID: IOPMAssertionID) {
        self.assertionID = assertionID
    }

    func release() {
        let idToRelease: IOPMAssertionID?
        lock.lock()
        idToRelease = assertionID
        assertionID = nil
        lock.unlock()

        if let idToRelease {
            IOPMAssertionRelease(idToRelease)
        }
    }

    deinit {
        release()
    }
}

/// Acquires `kIOPMAssertionTypePreventUserIdleSystemSleep` via IOKit.
struct SystemIdleSleepAssertionManager: IdleSleepAssertionManaging {
    func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)? {
        var assertionID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess else {
            logger.warn(
                "Unable to acquire idle-sleep power assertion",
                metadata: ["ior_status": "\(status)"]
            )
            return nil
        }
        return SystemIdleSleepAssertionToken(assertionID: assertionID)
    }
}
