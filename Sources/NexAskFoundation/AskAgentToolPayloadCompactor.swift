import Foundation

package enum AskAgentToolPayloadCompactor {
    private static let maxStringLength = 400
    private static let maxTopLevelArrayItems = 12
    private static let maxNestedArrayItems = 8

    package static func compact(_ payload: [String: Any]) -> [String: Any] {
        compactDictionary(payload, depth: 0)
    }

    private static func compactDictionary(_ dictionary: [String: Any], depth: Int) -> [String: Any] {
        var compacted: [String: Any] = [:]

        for (key, value) in dictionary {
            compacted[key] = compactValue(value, forKey: key, depth: depth)
        }

        return compacted
    }

    private static func compactValue(_ value: Any, forKey key: String, depth: Int) -> Any {
        switch value {
        case let string as String:
            return boundedString(string)
        case let array as [Any]:
            return compactArray(array, forKey: key, depth: depth)
        case let dictionary as [String: Any]:
            return compactDictionary(dictionary, depth: depth + 1)
        default:
            return value
        }
    }

    private static func compactArray(_ array: [Any], forKey key: String, depth: Int) -> Any {
        let limit = depth == 0 ? maxTopLevelArrayItems : maxNestedArrayItems
        let truncated = Array(array.prefix(limit)).map { compactValue($0, forKey: key, depth: depth + 1) }

        guard array.count > limit else {
            return truncated
        }

        return [
            "total_count": array.count,
            "truncated_count": array.count - limit,
            "items": truncated
        ]
    }

    private static func boundedString(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxStringLength else { return trimmed }
        let head = trimmed.prefix(max(0, maxStringLength - 16))
        return "\(head)… [truncated]"
    }
}
