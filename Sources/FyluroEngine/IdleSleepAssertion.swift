import Foundation
import IOKit.pwr_mgt

protocol IdleSleepAssertionToken: Sendable {
    func release()
}

protocol IdleSleepAssertionManaging: Sendable {
    func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)?
}

private final class ProcessActivityBox: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}

final class SystemIdleSleepAssertionToken: IdleSleepAssertionToken, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private var endProcessActivity: (@Sendable () -> Void)?
    private let releasePowerAssertion: @Sendable (IOPMAssertionID) -> Void

    init(
        assertionID: IOPMAssertionID?,
        endProcessActivity: (@Sendable () -> Void)? = nil,
        releasePowerAssertion: @escaping @Sendable (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }
    ) {
        self.assertionID = assertionID
        self.endProcessActivity = endProcessActivity
        self.releasePowerAssertion = releasePowerAssertion
    }

    func release() {
        let idToRelease: IOPMAssertionID?
        let activityEndToRun: (@Sendable () -> Void)?
        lock.lock()
        idToRelease = assertionID
        assertionID = nil
        activityEndToRun = endProcessActivity
        endProcessActivity = nil
        lock.unlock()

        if let idToRelease {
            releasePowerAssertion(idToRelease)
        }
        activityEndToRun?()
    }

    deinit {
        release()
    }
}

struct SystemIdleSleepAssertionManager: IdleSleepAssertionManaging {
    typealias CreatePowerAssertion = @Sendable (String) -> (status: IOReturn, assertionID: IOPMAssertionID)
    typealias ReleasePowerAssertion = @Sendable (IOPMAssertionID) -> Void
    typealias BeginProcessActivity = @Sendable (ProcessInfo.ActivityOptions, String) -> (@Sendable () -> Void)

    private let createPowerAssertion: CreatePowerAssertion
    private let releasePowerAssertion: ReleasePowerAssertion
    private let beginProcessActivity: BeginProcessActivity

    init(
        createPowerAssertion: @escaping CreatePowerAssertion = { reason in
            var assertionID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            return (status, assertionID)
        },
        releasePowerAssertion: @escaping ReleasePowerAssertion = { IOPMAssertionRelease($0) },
        beginProcessActivity: @escaping BeginProcessActivity = { options, reason in
            // OS workaround: IOPMAssertion prevents idle sleep, but macOS App Nap still
            // throttles disk I/O (disk:Y) and CPU in backgrounded GUI apps unless a
            // user-initiated ProcessInfo activity is active.
            let box = ProcessActivityBox(
                ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
            )
            return {
                ProcessInfo.processInfo.endActivity(box.token)
            }
        }
    ) {
        self.createPowerAssertion = createPowerAssertion
        self.releasePowerAssertion = releasePowerAssertion
        self.beginProcessActivity = beginProcessActivity
    }

    func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)? {
        let endActivity = beginProcessActivity(.userInitiated, reason)
        let powerResult = createPowerAssertion(reason)
        let acquiredAssertionID: IOPMAssertionID?
        if powerResult.status == kIOReturnSuccess {
            acquiredAssertionID = powerResult.assertionID
        } else {
            logger.warn(
                "Unable to acquire idle-sleep power assertion",
                metadata: ["ior_status": "\(powerResult.status)"]
            )
            acquiredAssertionID = nil
        }
        return SystemIdleSleepAssertionToken(
            assertionID: acquiredAssertionID,
            endProcessActivity: endActivity,
            releasePowerAssertion: releasePowerAssertion
        )
    }
}
