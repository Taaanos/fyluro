import Foundation

final class ThreadSafeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func recordIfNeeded(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if storedError == nil {
            storedError = error
        }
    }

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

struct TestFaultInjectionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct FailureContext {
    let phase: IngestPhase
    let message: String
}

struct IngestRuntimeError: Error {
    let phase: IngestPhase
    let message: String
    let receiptErrorRecorded: Bool

    init(phase: IngestPhase, message: String, receiptErrorRecorded: Bool = false) {
        self.phase = phase
        self.message = message
        self.receiptErrorRecorded = receiptErrorRecorded
    }
}

struct ReceiptOutcomeTotals {
    var copied = 0
    var verified = 0
    var verificationSkipped = 0
    var committed = 0
    var duplicateNotCopied = 0
    var conflictsRenamed = 0
    var errors = 0
    var plannedStageAndCommit = 0
}

struct FileMove: Hashable {
    let fromPath: String
    let toPath: String

    var payload: [String: String] {
        [
            "from": fromPath,
            "to": toPath,
        ]
    }
}

struct ReceiptTouchedPaths {
    private var createdDirectories: Set<String> = []
    private var writtenStagingFiles: Set<String> = []
    private var writtenFinalFiles: Set<String> = []
    private var moveOperations: Set<FileMove> = []
    private var deletedPaths: Set<String> = []

    private var plannedStagingFiles: Set<String> = []
    private var plannedFinalFiles: Set<String> = []
    private var plannedMoveOperations: Set<FileMove> = []

    private var writtenReceiptFiles: Set<String> = []

    mutating func addCreatedDirectory(_ path: String) {
        createdDirectories.insert(path)
    }

    mutating func addWrittenStagingFile(_ path: String) {
        writtenStagingFiles.insert(path)
    }

    mutating func addWrittenFinalFile(_ path: String) {
        writtenFinalFiles.insert(path)
    }

    mutating func addMove(from: String, to: String) {
        moveOperations.insert(FileMove(fromPath: from, toPath: to))
    }

    mutating func addDeletedPath(_ path: String) {
        deletedPaths.insert(path)
    }

    mutating func addPlannedStagingFile(_ path: String) {
        plannedStagingFiles.insert(path)
    }

    mutating func addPlannedFinalFile(_ path: String) {
        plannedFinalFiles.insert(path)
    }

    mutating func addPlannedMove(from: String, to: String) {
        plannedMoveOperations.insert(FileMove(fromPath: from, toPath: to))
    }

    mutating func addWrittenReceiptFile(_ path: String) {
        writtenReceiptFiles.insert(path)
    }

    func hasWrittenStagingFile(_ path: String) -> Bool {
        writtenStagingFiles.contains(path)
    }

    func hasMoveFromStaging(_ stagingPath: String) -> Bool {
        moveOperations.contains { $0.fromPath == stagingPath }
    }

    func payload(with receiptWriter: ReceiptWriter) -> [String: Any] {
        let receiptPaths = Set(receiptWriter.receiptPaths.map(\.path))
        return [
            "created_directories": createdDirectories.sorted(),
            "written_staging_files": writtenStagingFiles.sorted(),
            "written_final_files": writtenFinalFiles.sorted(),
            "move_operations": sortedMoves(moveOperations),
            "deleted_paths": deletedPaths.sorted(),
            "planned_staging_files": plannedStagingFiles.sorted(),
            "planned_final_files": plannedFinalFiles.sorted(),
            "planned_move_operations": sortedMoves(plannedMoveOperations),
            "written_receipt_files": writtenReceiptFiles.union(receiptPaths).sorted(),
        ]
    }

    private func sortedMoves(_ moves: Set<FileMove>) -> [[String: String]] {
        moves
            .sorted { lhs, rhs in
                if lhs.fromPath != rhs.fromPath {
                    return lhs.fromPath < rhs.fromPath
                }
                return lhs.toPath < rhs.toPath
            }
            .map(\.payload)
    }
}
