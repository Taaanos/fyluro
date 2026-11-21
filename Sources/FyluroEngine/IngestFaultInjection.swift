import Foundation

/// Test-only fault-injection knobs for the ingest pipeline. The CLI builds this
/// from environment variables (`.fromEnvironment()`, preserving the existing
/// `FYLURO_TEST_*` script contract); in-process tests inject explicit values
/// because parallel XCTest workers cannot safely mutate `setenv`.
public struct IngestFaultInjection: Sendable {
    public var failCopyOnNthFile: Int?
    public var failCopyMessage: String
    public var failCommitOnNthFile: Int?
    public var failCommitMessage: String
    public var corruptStagingBeforeVerify: Bool
    public var sleepBeforeCommitSeconds: Int?
    public var forceMissingCaptureDateRelativePaths: Set<String>
    public var receiptFailDestinationAppendAtEventIndex: Int?
    public var forceInsufficientDiskSpace: Bool

    public init(
        failCopyOnNthFile: Int? = nil,
        failCopyMessage: String = "Simulated copy failure",
        failCommitOnNthFile: Int? = nil,
        failCommitMessage: String = "Simulated commit failure",
        corruptStagingBeforeVerify: Bool = false,
        sleepBeforeCommitSeconds: Int? = nil,
        forceMissingCaptureDateRelativePaths: Set<String> = [],
        receiptFailDestinationAppendAtEventIndex: Int? = nil,
        forceInsufficientDiskSpace: Bool = false
    ) {
        self.failCopyOnNthFile = failCopyOnNthFile
        self.failCopyMessage = failCopyMessage
        self.failCommitOnNthFile = failCommitOnNthFile
        self.failCommitMessage = failCommitMessage
        self.corruptStagingBeforeVerify = corruptStagingBeforeVerify
        self.sleepBeforeCommitSeconds = sleepBeforeCommitSeconds
        self.forceMissingCaptureDateRelativePaths = forceMissingCaptureDateRelativePaths
        self.receiptFailDestinationAppendAtEventIndex = receiptFailDestinationAppendAtEventIndex
        self.forceInsufficientDiskSpace = forceInsufficientDiskSpace
    }

    public static let none = IngestFaultInjection()

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IngestFaultInjection {
        IngestFaultInjection(
            failCopyOnNthFile: IngestEnvironmentParsing.parsePositiveInt(
                name: "FYLURO_TEST_FAIL_COPY_ON_NTH_FILE",
                environment: environment
            ),
            failCopyMessage: environment["FYLURO_TEST_FAIL_COPY_ERROR_MESSAGE"] ?? "Simulated copy failure",
            failCommitOnNthFile: IngestEnvironmentParsing.parsePositiveInt(
                name: "FYLURO_TEST_FAIL_COMMIT_ON_NTH_FILE",
                environment: environment
            ),
            failCommitMessage: environment["FYLURO_TEST_FAIL_COMMIT_ERROR_MESSAGE"] ?? "Simulated commit failure",
            corruptStagingBeforeVerify: environment["FYLURO_TEST_CORRUPT_STAGING_BEFORE_VERIFY"] == "1",
            sleepBeforeCommitSeconds: IngestEnvironmentParsing.parsePositiveInt(
                name: "FYLURO_TEST_SLEEP_BEFORE_COMMIT_SECONDS",
                environment: environment
            ),
            forceMissingCaptureDateRelativePaths: IngestEnvironmentParsing.parseRelativePathSet(
                name: "FYLURO_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS",
                environment: environment
            ),
            receiptFailDestinationAppendAtEventIndex: IngestEnvironmentParsing.parsePositiveInt(
                name: "FYLURO_TEST_RECEIPT_FAIL_DEST_APPEND_AT_EVENT_INDEX",
                environment: environment
            ),
            forceInsufficientDiskSpace: environment["FYLURO_TEST_FORCE_INSUFFICIENT_DISK_SPACE"] == "1"
        )
    }
}
