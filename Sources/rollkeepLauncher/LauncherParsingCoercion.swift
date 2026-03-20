import Foundation

struct LauncherParsingCoercion {
    func parseJSONObject(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    func intValue(from value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    func int64Value(from value: Any?) -> Int64? {
        if let integer = value as? Int64 {
            return integer
        }
        if let integer = value as? Int {
            return Int64(integer)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }

    func boolValue(from value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func deduped(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }

    func extractStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [String] else {
            return nil
        }
        return deduped(values.filter { !$0.isEmpty })
    }

    func currentPath(from data: [String: Any]) -> String? {
        let keys = ["path", "source_path", "staging_path", "final_path"]
        for key in keys {
            if let path = data[key] as? String, !path.isEmpty {
                return path
            }
        }
        return nil
    }
}
