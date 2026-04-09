import Foundation

struct ScriptBalance: Equatable {
    let chineseLetterCount: Int
    let latinLetterCount: Int
    let otherLetterCount: Int

    var totalLetterCount: Int {
        chineseLetterCount + latinLetterCount + otherLetterCount
    }
}

enum TranslationMode: String {
    case fullTranslateToLocal = "full_translate_to_local"
    case fullTranslateToCounterpart = "full_translate_to_counterpart"
    case translateForeignSegmentsToLocal = "translate_foreign_segments_to_local"
}

struct TranslationRoutingDecision: Equatable {
    let targetLanguage: String
    let responseLanguage: String
    let mode: TranslationMode
    let detectedLanguage: String
}

struct SelectionContextWindow: Equatable {
    let selectedText: String
    let leadingContext: String?
    let trailingContext: String?
}

enum LanguageRoutingSupport {
    static func analyzeScripts(in text: String) -> ScriptBalance {
        var chineseLetterCount = 0
        var latinLetterCount = 0
        var otherLetterCount = 0

        for scalar in text.unicodeScalars {
            if isChineseScalar(scalar) {
                chineseLetterCount += 1
            } else if isASCIILetter(scalar) {
                latinLetterCount += 1
            } else if scalar.properties.isAlphabetic {
                otherLetterCount += 1
            }
        }

        return ScriptBalance(
            chineseLetterCount: chineseLetterCount,
            latinLetterCount: latinLetterCount,
            otherLetterCount: otherLetterCount
        )
    }

    static func detectedLanguage(for text: String) -> String {
        let balance = analyzeScripts(in: text)
        if balance.chineseLetterCount > 0, balance.chineseLetterCount >= balance.latinLetterCount + balance.otherLetterCount {
            return "zh"
        }
        return "en"
    }

    static func translationDecision(for text: String, uiLanguage: String) -> TranslationRoutingDecision {
        let localLanguage = normalizedLocalLanguage(from: uiLanguage)
        let counterpartLanguage = localLanguage == "zh" ? "en" : "zh"
        let balance = analyzeScripts(in: text)
        let detectedLanguage = detectedLanguage(for: text)

        let localLetterCount: Int
        let foreignLetterCount: Int
        if localLanguage == "zh" {
            localLetterCount = balance.chineseLetterCount
            foreignLetterCount = balance.latinLetterCount + balance.otherLetterCount
        } else {
            localLetterCount = balance.latinLetterCount + balance.otherLetterCount
            foreignLetterCount = balance.chineseLetterCount
        }

        let totalLetterCount = localLetterCount + foreignLetterCount
        guard totalLetterCount > 0 else {
            return TranslationRoutingDecision(
                targetLanguage: localLanguage,
                responseLanguage: localLanguage,
                mode: .fullTranslateToLocal,
                detectedLanguage: detectedLanguage
            )
        }

        let localRatio = Double(localLetterCount) / Double(totalLetterCount)

        if localLetterCount == 0, foreignLetterCount > 0 {
            return TranslationRoutingDecision(
                targetLanguage: localLanguage,
                responseLanguage: localLanguage,
                mode: .fullTranslateToLocal,
                detectedLanguage: detectedLanguage
            )
        }

        if foreignLetterCount == 0, localLetterCount > 0 {
            return TranslationRoutingDecision(
                targetLanguage: counterpartLanguage,
                responseLanguage: counterpartLanguage,
                mode: .fullTranslateToCounterpart,
                detectedLanguage: detectedLanguage
            )
        }

        if localRatio <= 0.28 {
            return TranslationRoutingDecision(
                targetLanguage: localLanguage,
                responseLanguage: localLanguage,
                mode: .fullTranslateToLocal,
                detectedLanguage: detectedLanguage
            )
        }

        if localRatio >= 0.72 {
            return TranslationRoutingDecision(
                targetLanguage: counterpartLanguage,
                responseLanguage: counterpartLanguage,
                mode: .fullTranslateToCounterpart,
                detectedLanguage: detectedLanguage
            )
        }

        return TranslationRoutingDecision(
            targetLanguage: localLanguage,
            responseLanguage: localLanguage,
            mode: .translateForeignSegmentsToLocal,
            detectedLanguage: detectedLanguage
        )
    }

    static func selectionContext(
        selectedText: String,
        capturedValue: String?,
        selectedRange: NSRange?,
        maxContextLength: Int = 180
    ) -> SelectionContextWindow? {
        guard let capturedValue,
              let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.length > 0 else {
            return nil
        }

        let nsCapturedValue = capturedValue as NSString
        guard selectedRange.location + selectedRange.length <= nsCapturedValue.length else {
            return nil
        }

        let selectedTextFromCapturedValue = nsCapturedValue.substring(with: selectedRange)
        guard selectionLooselyMatches(selectedText, selectedTextFromCapturedValue) else {
            return nil
        }

        let leadingLength = min(maxContextLength, selectedRange.location)
        let trailingLength = min(maxContextLength, nsCapturedValue.length - selectedRange.location - selectedRange.length)

        let leadingRange = NSRange(location: selectedRange.location - leadingLength, length: leadingLength)
        let trailingRange = NSRange(location: selectedRange.location + selectedRange.length, length: trailingLength)

        let leadingContext = clippedContext(
            nsCapturedValue.substring(with: leadingRange),
            clippedAtStart: leadingRange.location > 0,
            clippedAtEnd: false
        )
        let trailingContext = clippedContext(
            nsCapturedValue.substring(with: trailingRange),
            clippedAtStart: false,
            clippedAtEnd: trailingRange.location + trailingRange.length < nsCapturedValue.length
        )

        guard leadingContext != nil || trailingContext != nil else {
            return nil
        }

        return SelectionContextWindow(
            selectedText: selectedText,
            leadingContext: leadingContext,
            trailingContext: trailingContext
        )
    }

    static func foreignReadableSegments(in text: String, localLanguage: String) -> [String] {
        let normalizedLocal = normalizedLocalLanguage(from: localLanguage)
        guard normalizedLocal == "zh" else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])(?:[A-Za-z]+(?:[’'-][A-Za-z]+)?|[A-Z]{2,})(?:\s+(?:[A-Za-z]+(?:[’'-][A-Za-z]+)?|[A-Z]{2,})){0,7}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        var segments: [String] = []
        var seen: Set<String> = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            guard !isAdjacentToIdentifierPunctuation(in: text, range: range) else { continue }
            let segment = String(text[range])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,;:!?()[]{}<>\"'`*_~，。！？：；、“”‘’（）【】"))
            guard !segment.isEmpty else { continue }
            guard !looksLikeStandaloneIdentifier(segment) else { continue }
            let normalized = segment.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            segments.append(segment)
        }
        return segments
    }

    private static func normalizedLocalLanguage(from uiLanguage: String) -> String {
        let normalized = uiLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("zh") ? "zh" : "en"
    }

    private static func looksLikeStandaloneIdentifier(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return true }
        if compact.contains("://") || compact.contains("@") {
            return true
        }
        if compact.range(of: #"[\{\}\[\]\(\)/\\._]"#, options: .regularExpression) != nil {
            return true
        }
        if compact.contains("-"),
           compact.range(
            of: #"^(?:[A-Za-z]+(?:-[A-Za-z]+)+(?:\s+[A-Za-z]+(?:-[A-Za-z]+)*)*)$"#,
            options: .regularExpression
           ) == nil {
            return true
        }
        let tokens = compact.split(whereSeparator: \.isWhitespace)
        if tokens.count == 1, compact == compact.uppercased(), compact.count <= 6 {
            return true
        }
        return false
    }

    private static func isAdjacentToIdentifierPunctuation(in text: String, range: Range<String.Index>) -> Bool {
        let previous = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        let markerSet: Set<Character> = ["/", "\\", ".", "_", ":"]
        return previous.map { markerSet.contains($0) } == true || next.map { markerSet.contains($0) } == true
    }

    private static func isChineseScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func selectionLooselyMatches(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLeft = normalizedComparable(lhs)
        let normalizedRight = normalizedComparable(rhs)
        guard !normalizedLeft.isEmpty, !normalizedRight.isEmpty else {
            return false
        }

        return normalizedLeft == normalizedRight
            || normalizedLeft.contains(normalizedRight)
            || normalizedRight.contains(normalizedLeft)
    }

    private static func normalizedComparable(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private static func clippedContext(_ text: String, clippedAtStart: Bool, clippedAtEnd: Bool) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return nil
        }

        var rendered = normalized
        if clippedAtStart {
            rendered = "..." + rendered
        }
        if clippedAtEnd {
            rendered += "..."
        }
        return rendered
    }
}
