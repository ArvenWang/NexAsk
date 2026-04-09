import Foundation

struct StreamingTextAssembler {
    private(set) var fullText = ""

    mutating func append(incoming rawIncoming: String) -> String {
        let incoming = rawIncoming.replacingOccurrences(of: "\r\n", with: "\n")
        guard !incoming.isEmpty else { return "" }

        guard !fullText.isEmpty else {
            fullText = incoming
            return incoming
        }

        if incoming == fullText || fullText.hasSuffix(incoming) {
            return ""
        }

        if incoming.hasPrefix(fullText) {
            let remainder = String(incoming.dropFirst(fullText.count))
            fullText = incoming
            return remainder
        }

        let overlap = longestSuffixPrefixOverlap(current: fullText, incoming: incoming)
        if overlap > 0 {
            let remainder = String(incoming.dropFirst(overlap))
            fullText += remainder
            return remainder
        }

        fullText += incoming
        return incoming
    }

    private func longestSuffixPrefixOverlap(current: String, incoming: String) -> Int {
        let currentScalars = Array(current)
        let incomingScalars = Array(incoming)
        let maxOverlap = min(currentScalars.count, incomingScalars.count)
        guard maxOverlap > 0 else { return 0 }

        for size in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(currentScalars.suffix(size)) == Array(incomingScalars.prefix(size)) {
                return size
            }
        }
        return 0
    }
}
