import Foundation
import FyluroCore

enum IngestFailureContextResolver {
    static func resolve(_ error: Error) -> FailureContext {
        if let sourceError = error as? SourceScannerError {
            switch sourceError {
            case .unreadableSourceRoot(let path):
                return FailureContext(
                    phase: .scan,
                    message: "Source root unreadable: \(path)"
                )
            case .sourceBoundaryViolation(let path, let sourceRoot):
                return FailureContext(
                    phase: .scan,
                    message: "Source scan boundary violation: \(path) escapes \(sourceRoot)"
                )
            }
        }

        if let ingestError = error as? IngestRuntimeError {
            return FailureContext(
                phase: ingestError.phase,
                message: ingestError.message
            )
        }

        return FailureContext(
            phase: .finalize,
            message: error.localizedDescription
        )
    }
}
