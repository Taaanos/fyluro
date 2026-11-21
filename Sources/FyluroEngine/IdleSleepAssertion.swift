import Foundation
import IOKit.pwr_mgt

protocol IdleSleepAssertionToken: Sendable {
    func release()
}

protocol IdleSleepAssertionManaging: Sendable {
    func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)?
}

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
