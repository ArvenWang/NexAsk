import Foundation

struct TextURLDetection: Equatable {
    let url: URL
    let isStandalone: Bool
}

enum TextURLDetector {
    static func detect(in text: String) -> TextURLDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let detected = detectUsingDataDetector(in: trimmed) {
            return TextURLDetection(url: detected, isStandalone: isStandaloneSelection(trimmed, matchedURL: detected))
        }

        let tokens = candidateTokens(from: trimmed)
        for token in tokens {
            guard let url = normalizeURLToken(token) else { continue }
            return TextURLDetection(url: url, isStandalone: isStandaloneSelection(trimmed, matchedURL: url))
        }

        return nil
    }

    static func containsURL(in text: String) -> Bool {
        detect(in: text) != nil
    }

    static func isStandaloneURL(_ text: String) -> Bool {
        detect(in: text)?.isStandalone == true
    }

    private static func detectUsingDataDetector(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let matches = detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: text) else { continue }
            let matchedText = String(text[range])
            if let normalized = normalizeDetectedURL(url, matchedText: matchedText) {
                return normalized
            }
        }
        return nil
    }

    private static func normalizeDetectedURL(_ url: URL, matchedText: String) -> URL? {
        let trimmedMatch = matchedText.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>\"'“”‘’.,;:!?"))
        if trimmedMatch.range(of: #"^(?:https?://|www\.)"#, options: .regularExpression) == nil,
           let normalized = normalizeURLToken(trimmedMatch) {
            return normalized
        }
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return url
        }
        let absolute = url.absoluteString
        if absolute.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(absolute)")
        }
        return normalizeURLToken(absolute)
    }

    private static func candidateTokens(from text: String) -> [String] {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>\"'“”‘’.,;:!?"))
            }
            .filter { !$0.isEmpty }
    }

    private static func normalizeURLToken(_ token: String) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n"), !trimmed.contains("@") else {
            return nil
        }

        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }

        if trimmed.lowercased().hasPrefix("www."),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }

        let bareDomainPattern = #"^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:/[^\s]*)?(?:\?[^\s]*)?(?:#[^\s]*)?$"#
        guard trimmed.range(of: bareDomainPattern, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func isStandaloneSelection(_ text: String, matchedURL: URL) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n") else { return false }
        if let normalized = normalizeURLToken(trimmed) {
            return normalized.absoluteString == matchedURL.absoluteString
        }
        return false
    }
}
