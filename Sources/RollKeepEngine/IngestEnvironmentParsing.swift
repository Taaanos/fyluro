import Foundation

enum IngestEnvironmentParsing {
    static func parsePositiveInt(name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        guard let rawValue = environment[name] else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else {
            return nil
        }
        return value
    }

    static func parseRelativePathSet(name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        guard let rawValue = environment[name] else {
            return []
        }

        return Set(rawValue
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )
    }
}
