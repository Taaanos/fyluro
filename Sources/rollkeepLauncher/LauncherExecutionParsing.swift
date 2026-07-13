import Foundation

enum LauncherPhase: String, Equatable {
    case idle
    case scan
    case plan
    case copy
    case verify
    case commit
    case finalize
    case finished

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .scan:
            return "Scan"
        case .plan:
            return "Plan"
        case .copy:
            return "Copy"
        case .verify:
            return "Verify"
        case .commit:
            return "Commit"
        case .finalize:
            return "Finalize"
        case .finished:
            return "Finished"
        }
    }

    static func fromReceiptPhase(_ value: String) -> LauncherPhase? {
        switch value {
        case "scan":
            return .scan
        case "plan":
            return .plan
        case "copy":
            return .copy
        case "verify":
            return .verify
        case "commit":
            return .commit
        case "finalize":
            return .finalize
        default:
            return nil
        }
    }
}

enum LauncherRunResult: Equatable {
    case success
    case failure
}

struct ReceiptErrorItem: Equatable {
    let eventIndex: Int
    let phase: LauncherPhase?
    let message: String
    let paths: [String]
}

struct ParsedReceiptUpdate: Equatable {
    struct PhaseTiming: Equatable {
        let phase: LauncherPhase
        let milliseconds: Int
    }

    var phase: LauncherPhase?
    var scannedCandidateCount: Int?
    var scannedFilesCheckedCount: Int?
    var scannedCheckedBytes: Int64?
    var scanPhotoCount: Int? = nil
    var scanVideoCount: Int? = nil
    var scanPhotoBytes: Int64? = nil
    var scanVideoBytes: Int64? = nil
    var plannedStageAndCommit: Int?
    var duplicateNotCopied: Int?
    var copiedIncrement = 0
    var verifiedIncrement = 0
    var committedIncrement = 0
    var currentFilePath: String?
    var finalizedCommittedCount: Int?
    var finalizedDuplicateNotCopiedCount: Int?
    var finalizedIdempotentRerun: Bool?
    var finalizedPhaseTimings: [PhaseTiming]?
    var finalizedTotalDurationMs: Int?
    var pdfSummaryPath: String?
    var errorItem: ReceiptErrorItem?
    var touchedPaths: [String]?
    var createdDirectories: [String]?
}
