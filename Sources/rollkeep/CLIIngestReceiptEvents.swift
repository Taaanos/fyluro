import Foundation

extension RollkeepCLI {
    func appendCopyResults(
        _ results: [StagingCopyEngine.FileResult],
        receiptWriter: ReceiptWriter,
        touchedPaths: inout ReceiptTouchedPaths,
        outcomeTotals: inout ReceiptOutcomeTotals
    ) throws {
        for result in results {
            outcomeTotals.copied += 1
            touchedPaths.addWrittenStagingFile(result.stagingPath)

            try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: [
                "path": result.relativePath,
                "source_path": result.sourcePath,
                "staging_path": result.stagingPath,
                "final_path": result.finalPath,
                "bytes": result.bytesCopied,
                "hash_sha256": result.sourceHashSHA256,
                "status": "copied_to_staging",
                "executed": true,
            ])

            try receiptWriter.append(eventType: .fileVerifyStarted, phase: .verify, data: [
                "path": result.relativePath,
                "source_path": result.sourcePath,
                "staging_path": result.stagingPath,
                "status": "started",
                "executed": true,
            ])

            outcomeTotals.verified += 1
            let stagedHash = result.verifiedHashSHA256 ?? "missing"
            try receiptWriter.append(eventType: .fileVerified, phase: .verify, data: [
                "path": result.relativePath,
                "source_path": result.sourcePath,
                "staging_path": result.stagingPath,
                "outcome": "verified",
                "status": "verified",
                "hash_sha256_source": result.sourceHashSHA256,
                "hash_sha256_staging": stagedHash,
                "hash_match": result.sourceHashSHA256 == stagedHash,
                "bytes": result.bytesCopied,
                "executed": true,
            ])
        }
    }
    func appendCopyFailure(
        _ failure: StagingCopyEngine.FileFailure,
        receiptWriter: ReceiptWriter,
        touchedPaths: inout ReceiptTouchedPaths,
        outcomeTotals: inout ReceiptOutcomeTotals
    ) throws {
        var copiedData: [String: Any] = [
            "path": failure.relativePath,
            "source_path": failure.sourcePath,
            "staging_path": failure.stagingPath,
            "final_path": failure.finalPath,
            "executed": true,
        ]

        if let expectedBytes = failure.expectedBytes {
            copiedData["expected_bytes"] = expectedBytes
        }
        if let actualBytes = failure.actualBytes {
            copiedData["bytes"] = actualBytes
        }
        if let expectedHash = failure.expectedHashSHA256 {
            copiedData["hash_sha256"] = expectedHash
        }

        switch failure.phase {
        case .verify:
            outcomeTotals.copied += 1
            touchedPaths.addWrittenStagingFile(failure.stagingPath)

            copiedData["status"] = "copied_to_staging"
            copiedData["outcome"] = "copied_to_staging"
            try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: copiedData)

            try receiptWriter.append(eventType: .fileVerifyStarted, phase: .verify, data: [
                "path": failure.relativePath,
                "source_path": failure.sourcePath,
                "staging_path": failure.stagingPath,
                "status": "started",
                "executed": true,
            ])

            var verifyData: [String: Any] = [
                "path": failure.relativePath,
                "source_path": failure.sourcePath,
                "staging_path": failure.stagingPath,
                "outcome": "failed",
                "status": "failed",
                "error": failure.message,
                "executed": true,
            ]
            if let expectedBytes = failure.expectedBytes {
                verifyData["expected_bytes"] = expectedBytes
            }
            if let actualBytes = failure.actualBytes {
                verifyData["bytes"] = actualBytes
            }
            if let expectedHash = failure.expectedHashSHA256 {
                verifyData["hash_sha256_source"] = expectedHash
            }
            if let actualHash = failure.actualHashSHA256 {
                verifyData["hash_sha256_staging"] = actualHash
                verifyData["hash_match"] = failure.expectedHashSHA256 == actualHash
            }

            try receiptWriter.append(eventType: .fileVerified, phase: .verify, data: verifyData)
        case .copy:
            copiedData["status"] = "failed"
            copiedData["outcome"] = "copy_failed"
            copiedData["error"] = failure.message
            try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: copiedData)
        case .scan, .plan, .commit, .finalize:
            break
        }

        var errorData: [String: Any] = [
            "path": failure.relativePath,
            "source_path": failure.sourcePath,
            "staging_path": failure.stagingPath,
            "final_path": failure.finalPath,
            "error": failure.message,
        ]
        if let expectedBytes = failure.expectedBytes {
            errorData["expected_bytes"] = expectedBytes
        }
        if let actualBytes = failure.actualBytes {
            errorData["bytes"] = actualBytes
        }
        if let expectedHash = failure.expectedHashSHA256 {
            errorData["hash_sha256_source"] = expectedHash
        }
        if let actualHash = failure.actualHashSHA256 {
            errorData["hash_sha256_staging"] = actualHash
        }

        try receiptWriter.append(eventType: .error, phase: failure.phase, data: errorData)
    }
    func appendCommitResults(
        _ results: [StagingCommitEngine.FileResult],
        receiptWriter: ReceiptWriter,
        touchedPaths: inout ReceiptTouchedPaths,
        outcomeTotals: inout ReceiptOutcomeTotals
    ) throws {
        for result in results {
            switch result.disposition {
            case .committed:
                outcomeTotals.committed += 1
                touchedPaths.addWrittenFinalFile(result.finalPath)
                touchedPaths.addMove(from: result.stagingPath, to: result.finalPath)

                if result.collisionResolved {
                    outcomeTotals.conflictsRenamed += 1
                    try receiptWriter.append(eventType: .conflictRenamed, phase: .commit, data: [
                        "path": result.relativePath,
                        "source_path": result.sourcePath,
                        "staging_path": result.stagingPath,
                        "planned_final_path": result.plannedFinalPath,
                        "final_path": result.finalPath,
                        "collision_suffix": result.collisionSuffix ?? 0,
                        "status": "resolved_at_commit",
                        "executed": true,
                    ])
                }

                var data: [String: Any] = [
                    "path": result.relativePath,
                    "source_path": result.sourcePath,
                    "staging_path": result.stagingPath,
                    "planned_final_path": result.plannedFinalPath,
                    "final_path": result.finalPath,
                    "outcome": result.disposition.rawValue,
                    "status": "committed",
                    "bytes": result.bytesCopied,
                    "hash_sha256_source": result.sourceHashSHA256,
                    "collision_renamed": result.collisionResolved,
                    "move_strategy": result.moveStrategy.rawValue,
                    "executed": true,
                ]
                if let collisionSuffix = result.collisionSuffix {
                    data["collision_suffix"] = collisionSuffix
                }
                try receiptWriter.append(eventType: .fileCommitted, phase: .commit, data: data)
            case .duplicateNotCopied:
                outcomeTotals.duplicateNotCopied += 1

                var duplicateData: [String: Any] = [
                    "path": result.relativePath,
                    "source_path": result.sourcePath,
                    "staging_path": result.stagingPath,
                    "planned_final_path": result.plannedFinalPath,
                    "final_path": result.finalPath,
                    "duplicate_of_path": result.finalPath,
                    "status": "duplicate_detected_at_commit",
                    "outcome": result.disposition.rawValue,
                    "hash_sha256_source": result.sourceHashSHA256,
                    "executed": true,
                ]
                if let collisionSuffix = result.collisionSuffix {
                    duplicateData["collision_suffix"] = collisionSuffix
                }
                try receiptWriter.append(eventType: .duplicateSkipped, phase: .commit, data: duplicateData)

                try receiptWriter.append(eventType: .fileCommitted, phase: .commit, data: [
                    "path": result.relativePath,
                    "source_path": result.sourcePath,
                    "staging_path": result.stagingPath,
                    "planned_final_path": result.plannedFinalPath,
                    "final_path": result.finalPath,
                    "duplicate_of_path": result.finalPath,
                    "outcome": result.disposition.rawValue,
                    "status": "skipped_duplicate",
                    "collision_renamed": result.collisionResolved,
                    "move_strategy": result.moveStrategy.rawValue,
                    "executed": true,
                ])
            }
        }
    }
    func appendCommitFailure(
        _ failure: StagingCommitEngine.FileFailure,
        remainingJobs: [StagingCommitEngine.FileJob],
        committedResults: [StagingCommitEngine.FileResult],
        receiptWriter: ReceiptWriter
    ) throws {
        var failedData: [String: Any] = [
            "path": failure.relativePath,
            "source_path": failure.sourcePath,
            "staging_path": failure.stagingPath,
            "planned_final_path": failure.plannedFinalPath,
            "final_path": failure.attemptedFinalPath ?? failure.plannedFinalPath,
            "outcome": "commit_failed",
            "status": "failed",
            "error": failure.message,
            "executed": true,
        ]
        if let attempted = failure.attemptedFinalPath {
            failedData["attempted_final_path"] = attempted
        }

        try receiptWriter.append(eventType: .fileCommitted, phase: .commit, data: failedData)

        for pending in remainingJobs {
            try receiptWriter.append(eventType: .fileCommitted, phase: .commit, data: [
                "path": pending.relativePath,
                "source_path": pending.sourcePath,
                "staging_path": pending.stagingPath,
                "planned_final_path": pending.plannedFinalPath,
                "final_path": pending.plannedFinalPath,
                "outcome": "pending_after_commit_failure",
                "status": "not_attempted_due_to_prior_failure",
                "executed": false,
            ])
        }

        let moved = committedResults
            .filter { $0.disposition == .committed }
            .map { result in
                [
                    "path": result.relativePath,
                    "staging_path": result.stagingPath,
                    "final_path": result.finalPath,
                ]
            }

        var remaining = remainingJobs.map { job in
            [
                "path": job.relativePath,
                "staging_path": job.stagingPath,
                "planned_final_path": job.plannedFinalPath,
            ]
        }
        remaining.insert([
            "path": failure.relativePath,
            "staging_path": failure.stagingPath,
            "planned_final_path": failure.plannedFinalPath,
        ], at: 0)

        try receiptWriter.append(eventType: .error, phase: .commit, data: [
            "path": failure.relativePath,
            "source_path": failure.sourcePath,
            "staging_path": failure.stagingPath,
            "planned_final_path": failure.plannedFinalPath,
            "attempted_final_path": failure.attemptedFinalPath ?? failure.plannedFinalPath,
            "error": failure.message,
            "moved_before_failure": moved,
            "remaining_after_failure": remaining,
        ])
    }

}
