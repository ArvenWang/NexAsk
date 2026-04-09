import Foundation

enum RuntimeTextSanitizer {
    static func sanitizeSummaryOutput(_ summary: String) -> String {
        let text = normalizeMultilineOutput(summary)
        guard !text.isEmpty else { return "" }
        return stripRepeatedTail(text, minChars: 8) ?? text
    }

    static func sanitizeTranslationOutput(sourceText: String, translated: String) -> String {
        let source = normalizeMultilineOutput(sourceText)
        let text = normalizeMultilineOutput(translated)
        guard !text.isEmpty else { return source }

        let isShortTerm = !source.contains("\n")
            && source.count <= 32
            && source.split(whereSeparator: \.isWhitespace).count <= 4

        var cleaned = stripRepeatedTail(text, minChars: isShortTerm ? 2 : 8) ?? text
        guard isShortTerm else { return cleaned }

        if cleaned.count.isMultiple(of: 2) {
            let half = cleaned.count / 2
            let index = cleaned.index(cleaned.startIndex, offsetBy: half)
            if cleaned[..<index] == cleaned[index...] {
                cleaned = String(cleaned[..<index])
            }
        }

        for size in stride(from: min(cleaned.count / 2, 16), through: 2, by: -1) {
            let suffix = String(cleaned.suffix(size))
            let prefix = String(cleaned.dropLast(size))
            if prefix.hasSuffix(suffix) {
                cleaned = prefix
                break
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? source
            : cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeTraceSummaryOutput(_ summary: String) -> String {
        var cleaned = summary
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*[-*]\s+"#,
            with: "",
            options: .regularExpression
        )

        let normalized = sanitizeSummaryOutput(cleaned)
        guard !normalized.isEmpty else { return "" }

        let lines = normalized.components(separatedBy: "\n")
        var kept: [String] = []
        for line in lines {
            let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if compact.isEmpty {
                if let last = kept.last, !last.isEmpty {
                    kept.append("")
                }
                continue
            }

            let lowered = compact.lowercased()
            if lowered.hasPrefix("最佳链接")
                || lowered.hasPrefix("推荐入口")
                || lowered.hasPrefix("best link")
                || lowered.hasPrefix("recommended link")
                || lowered.hasPrefix("recommended source") {
                break
            }

            kept.append(compact)
        }

        return normalizeMultilineOutput(kept.joined(separator: "\n"))
    }

    static func sanitizeExplainStreamText(_ explanation: String) -> String {
        var cleaned = explanation
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*[-*]\s+"#,
            with: "",
            options: .regularExpression
        )
        return cleaned
    }

    static func sanitizeExplanationOutput(_ explanation: String) -> String {
        let normalized = sanitizeSummaryOutput(sanitizeExplainStreamText(explanation)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("\n") else { return normalized }
        var lines = normalized.components(separatedBy: "\n")
        let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if lines.count > 1,
           first.count <= 10,
           first.range(of: #"[。！？!?：:]"#, options: .regularExpression) == nil {
            lines.removeFirst()
            return normalizeMultilineOutput(lines.joined(separator: "\n"))
        }
        return normalized
    }

    static func sanitizeReplyOutput(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<calendar_intent>.*?</calendar_intent>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<kb_refs>.*?</kb_refs>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<calendar_intent>.*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<kb_refs>.*$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = sanitizeExplainStreamText(cleaned)
        return sanitizeSummaryOutput(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fallbackExplain(text: String, languageCode: String) -> String {
        let compact = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let isEnglish = AppLanguage.from(languageCode: languageCode) == .english
        guard !compact.isEmpty else {
            return isEnglish
                ? "This item needs more context before it can be explained clearly."
                : "这是一个需要进一步上下文才能解释清楚的内容。"
        }

        if compact.count <= 16 {
            return isEnglish
                ? "This refers to \"\(compact)\", likely a concept or object that becomes clearer with a bit more context."
                : "这是「\(compact)」相关的概念或对象，适合结合具体上下文进一步理解。"
        }

        let preview = String(compact.prefix(32))
        return isEnglish
            ? "This passage is describing \"\(preview)\", and it reads more like an explanation of a concept, feature, or object."
            : "这段内容描述的是「\(preview)」，更像是在说明一个概念、功能或对象的含义。"
    }

    static func fallbackGenericSkillOutput(text: String, resultType: SkillResultType) -> String {
        let normalized = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        if resultType == .summaryText {
            return normalized.count > 220 ? String(normalized.prefix(220)) + "..." : normalized
        }
        return normalized
    }

    private static func normalizeMultilineOutput(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        var cleanedLines: [String] = []
        var blankRun = 0
        for line in normalized.components(separatedBy: "\n") {
            let compactLine = line.replacingOccurrences(
                of: #"[ \t]+"#,
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            if compactLine.isEmpty {
                blankRun += 1
                if blankRun <= 1 {
                    cleanedLines.append("")
                }
                continue
            }

            blankRun = 0
            cleanedLines.append(compactLine)
        }

        while cleanedLines.first == "" {
            cleanedLines.removeFirst()
        }
        while cleanedLines.last == "" {
            cleanedLines.removeLast()
        }

        return cleanedLines.joined(separator: "\n")
    }

    private static func stripRepeatedTail(_ text: String, minChars: Int) -> String? {
        var compact = text.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty else { return nil }

        if compact.count.isMultiple(of: 2) {
            let half = compact.count / 2
            let index = compact.index(compact.startIndex, offsetBy: half)
            if compact[..<index] == compact[index...] {
                compact = String(compact[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let units = splitSentenceUnits(compact)
        let maxUnitGroup = min(units.count / 2, 3)
        if maxUnitGroup > 0 {
            for size in stride(from: maxUnitGroup, through: 1, by: -1) {
                let prefix = Array(units.dropLast(size))
                let suffix = Array(units.suffix(size))
                guard !prefix.isEmpty else { continue }
                if Array(prefix.suffix(size)) == suffix && suffix.joined().count >= minChars {
                    compact = prefix.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        let maxSize = min(compact.count / 2, 160)
        if maxSize >= minChars {
            for size in stride(from: maxSize, through: minChars, by: -1) {
                let suffix = String(compact.suffix(size))
                let prefix = String(compact.dropLast(size))
                let trimmedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSuffix.isEmpty else { continue }
                if prefix.hasSuffix(suffix) || prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(trimmedSuffix) {
                    compact = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        return compact
    }

    private static func splitSentenceUnits(_ text: String) -> [String] {
        let pattern = #".*?(?:[。！？!?；;\n]+|(?:\.(?=\s|$))+|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return [text]
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let fragment = String(text[range])
            return fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fragment
        }
    }
}

struct RuntimeOutputValidation {
    let isValid: Bool
    let reason: String

    static let valid = RuntimeOutputValidation(isValid: true, reason: "ok")
}

enum RuntimeOutputGuard {
    static func validate(
        skillID: String,
        sourceText: String,
        outputText: String,
        responseLanguage: String,
        targetLanguage: String? = nil
    ) -> RuntimeOutputValidation {
        let output = normalizedComparableText(outputText)
        guard !output.isEmpty else {
            return .init(isValid: false, reason: "empty_output")
        }

        switch skillID {
        case "translate":
            let expectedLanguage = targetLanguage ?? responseLanguage
            if isLikelyEcho(sourceText: sourceText, outputText: outputText),
               !canAcceptUnchangedTranslation(sourceText: sourceText),
               !canAcceptAnchorOnlyMixedTranslation(sourceText: sourceText, expectedLanguage: expectedLanguage) {
                return .init(isValid: false, reason: "echo_source_text")
            }

            if containsLongSourceExcerpt(sourceText: sourceText, outputText: outputText, minimumLength: 28) {
                return .init(isValid: false, reason: "echo_source_text")
            }

            if hasUntranslatedMixedSegments(
                sourceText: sourceText,
                outputText: outputText,
                expectedLanguage: expectedLanguage
            ) {
                return .init(isValid: false, reason: "untranslated_mixed_segments")
            }

            if isSuspiciouslyShortTranslation(sourceText: sourceText, outputText: outputText) {
                return .init(isValid: false, reason: "translation_too_short")
            }

            if !matchesExpectedOutputLanguage(outputText, responseLanguage: expectedLanguage) {
                return .init(isValid: false, reason: "language_mismatch")
            }

            return .valid

        case "trace":
            if isLikelyEcho(sourceText: sourceText, outputText: outputText)
                || containsLongSourceExcerpt(sourceText: sourceText, outputText: outputText, minimumLength: 28) {
                return .init(isValid: false, reason: "echo_source_text")
            }
            return .valid

        case "schedule", "compress":
            return .valid

        default:
            if isLikelyEcho(sourceText: sourceText, outputText: outputText) {
                return .init(isValid: false, reason: "echo_source_text")
            }
            return .valid
        }
    }

    static func isLikelyEcho(sourceText: String, outputText: String) -> Bool {
        let source = normalizedComparableText(sourceText)
        let output = normalizedComparableText(outputText)
        guard !source.isEmpty, !output.isEmpty else { return false }

        if source == output {
            return true
        }

        let minLength = min(source.count, output.count)
        let maxLength = max(source.count, output.count)
        if minLength >= 12,
           Double(minLength) / Double(maxLength) >= 0.86,
           (source.hasPrefix(output) || output.hasPrefix(source) || source.hasSuffix(output) || output.hasSuffix(source)) {
            return true
        }

        if minLength >= 120, source.contains(output) || output.contains(source) {
            return true
        }

        let sharedPrefix = sharedPrefixLength(source, output)
        if sharedPrefix >= max(12, min(80, Int(Double(min(source.count, output.count)) * 0.55))),
           output.count >= sharedPrefix + 8 {
            return true
        }

        return false
    }

    private static func canAcceptUnchangedTranslation(sourceText: String) -> Bool {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("\n") || trimmed.count > 18 {
            return false
        }

        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count <= 2 else { return false }

        let hasCJK = trimmed.contains { "\u{4E00}" <= $0 && $0 <= "\u{9FFF}" }
        let hasASCIIAlpha = trimmed.contains { $0.isASCII && $0.isLetter }
        return !(hasCJK && hasASCIIAlpha)
    }

    private static func canAcceptAnchorOnlyMixedTranslation(sourceText: String, expectedLanguage: String) -> Bool {
        let target = expectedLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target.hasPrefix("zh") else { return false }

        let signals = languageSignalCounts(sourceText)
        guard signals.cjk > 0, signals.latin > 0 else { return false }

        return translatableForeignSegments(in: sourceText, expectedLanguage: expectedLanguage).isEmpty
    }

    private static func matchesExpectedOutputLanguage(_ text: String, responseLanguage: String) -> Bool {
        let normalized = normalizedComparableText(text)
        if normalized.isEmpty {
            return true
        }

        let (cjkCount, latinCount) = languageSignalCounts(text)
        let target = responseLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if target.hasPrefix("zh") {
            if cjkCount == 0 {
                return latinCount == 0
            }
            return true
        }

        if cjkCount == 0 {
            return true
        }
        return latinCount >= max(12, cjkCount * 3)
    }

    private static func isSuspiciouslyShortTranslation(sourceText: String, outputText: String) -> Bool {
        let normalizedSource = normalizedComparableText(sourceText)
        let normalizedOutput = normalizedComparableText(outputText)
        guard normalizedSource.count >= 240, !normalizedOutput.isEmpty else {
            return false
        }

        let ratio = Double(normalizedOutput.count) / Double(normalizedSource.count)
        return ratio < 0.18
    }

    private static func hasUntranslatedMixedSegments(
        sourceText: String,
        outputText: String,
        expectedLanguage: String
    ) -> Bool {
        let target = expectedLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target.hasPrefix("zh") else { return false }

        let sourceSignals = languageSignalCounts(sourceText)
        guard sourceSignals.cjk > 0, sourceSignals.latin > 0 else { return false }

        let readableSegments = translatableForeignSegments(in: sourceText, expectedLanguage: expectedLanguage)
        guard !readableSegments.isEmpty else { return false }

        let preservedReadableSegments = readableSegments.filter { segment in
            outputText.range(of: segment, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if !preservedReadableSegments.isEmpty {
            return true
        }

        let preservedResidualTokens = translatableForeignTokens(from: readableSegments).filter { token in
            outputContainsToken(token, in: outputText)
        }
        return !preservedResidualTokens.isEmpty
    }

    private static func translatableForeignSegments(in sourceText: String, expectedLanguage: String) -> [String] {
        LanguageRoutingSupport.foreignReadableSegments(
            in: sourceText,
            localLanguage: expectedLanguage
        ).filter { segment in
            !isPreservableAnchorPhrase(segment)
        }
    }

    private static func translatableForeignTokens(from segments: [String]) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        for segment in segments {
            for token in segment
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,;:!?()[]{}<>\"'`*_~，。！？：；、“”‘’（）【】")) })
            {
                guard !token.isEmpty else { continue }
                guard !isPreservableAnchorToken(token) else { continue }
                let normalized = token.lowercased()
                guard seen.insert(normalized).inserted else { continue }
                ordered.append(token)
            }
        }

        return ordered
    }

    private static func isPreservableAnchorPhrase(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return false }
        if tokens.count == 1 {
            return isPreservableAnchorToken(tokens[0])
        }
        return tokens.allSatisfy(isStrongPreservableAnchorToken)
    }

    private static func isPreservableAnchorToken(_ token: String) -> Bool {
        let compact = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return false }

        return isStrongPreservableAnchorToken(compact)
            || compact.range(of: #"^[A-Z][a-z]{2,24}$"#, options: .regularExpression) != nil
    }

    private static func isStrongPreservableAnchorToken(_ token: String) -> Bool {
        let compact = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return false }

        if compact.range(of: #"^[A-Z0-9]{2,8}$"#, options: .regularExpression) != nil {
            return true
        }

        return compact.range(of: #"[A-Z].*[A-Z]"#, options: .regularExpression) != nil
    }

    private static func containsLongSourceExcerpt(
        sourceText: String,
        outputText: String,
        minimumLength: Int
    ) -> Bool {
        let normalizedSource = normalizedComparableText(sourceText)
        let normalizedOutput = normalizedComparableText(outputText)
        guard !normalizedSource.isEmpty, !normalizedOutput.isEmpty else { return false }

        if normalizedSource.count >= minimumLength {
            let prefixEnd = normalizedSource.index(normalizedSource.startIndex, offsetBy: minimumLength)
            let prefix = String(normalizedSource[..<prefixEnd])
            if normalizedOutput.contains(prefix) {
                return true
            }
        }

        let fragments = sourceText.components(separatedBy: CharacterSet(charactersIn: "\n。！？!?；;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minimumLength }

        for fragment in fragments {
            let normalizedFragment = normalizedComparableText(fragment)
            guard normalizedFragment.count >= minimumLength else { continue }
            if normalizedOutput.contains(normalizedFragment) {
                return true
            }
        }

        return false
    }

    private static func outputContainsToken(_ token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = #"(?i)(?<![A-Za-z0-9])\#(escaped)(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: nsRange) != nil
    }

    private static func languageSignalCounts(_ text: String) -> (cjk: Int, latin: Int) {
        var cjk = 0
        var latin = 0
        for char in text {
            if "\u{4E00}" <= char && char <= "\u{9FFF}" {
                cjk += 1
            } else if char.isASCII && char.isLetter {
                latin += 1
            }
        }
        return (cjk, latin)
    }

    private static func latinWordTokens(in text: String) -> [String] {
        let lowered = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"[a-z][a-z0-9._/-]*"#) else { return [] }
        let nsRange = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        return regex.matches(in: lowered, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: lowered) else { return nil }
            return String(lowered[range])
        }
    }

    private static func normalizedComparableText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[[:punct:]]+"#, with: "", options: .regularExpression)
    }

    private static func sharedPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
    }
}

struct TraceIntentDescriptor: Equatable {
    let type: String
    let summary: String
    let actionGoal: String
}

struct TracePlanDescriptor: Equatable {
    let intent: TraceIntentDescriptor
    let primaryEntityName: String
    let entityType: String
    let whyThis: String
    let ownerHints: [String]
    let searchQueries: [String]
}

package enum TraceRuntimeSupport {
    private static let searchResultBaseURL = URL(string: "https://html.duckduckgo.com")!
    private static let blockedOfficialHosts: Set<String> = [
        "duckduckgo.com",
        "html.duckduckgo.com",
        "36kr.com",
        "zhihu.com",
        "x.com",
        "twitter.com",
        "medium.com",
        "techcrunch.com",
        "theverge.com",
        "reddit.com",
        "wikipedia.org",
        "weixin.qq.com",
        "mp.weixin.qq.com",
        "bilibili.com",
        "youtube.com",
        "baidu.com",
        "sohu.com",
        "qq.com",
        "sina.com.cn"
    ]
    private static let referenceDomains: Set<String> = [
        "github.com",
        "huggingface.co",
        "arxiv.org",
        "openrouter.ai",
        "platform.openai.com",
        "developers.cloudflare.com"
    ]
    private static let newsDomains: Set<String> = [
        "36kr.com",
        "techcrunch.com",
        "theverge.com",
        "zhihu.com",
        "reddit.com",
        "medium.com",
        "x.com",
        "twitter.com"
    ]
    private static let genericEntityStoplist: Set<String> = [
        "官网", "官方", "入口", "文档", "教程", "功能", "能力", "模型", "平台",
        "产品", "页面", "网站", "工具", "公司", "项目", "仓库", "文章", "博客",
        "api", "docs", "blog", "announcement", "update", "release"
    ]
    private static let commonEntityStoplist: Set<String> = [
        "OpenAI", "Google", "Apple", "Microsoft", "Meta", "腾讯", "阿里", "字节", "百度"
    ]

    static func inferIntent(for text: String, languageCode: String) -> TraceIntentDescriptor {
        let lowered = text.lowercased()

        let experienceTerms = ["免费", "试用", "体验", "demo", "playground", "preview", "beta", "入口"]
        let officialSourceTerms = ["官宣", "公告", "发布", "更新", "版本", "changelog", "announcement", "blog"]
        let docsTerms = ["文档", "docs", "api", "接入", "参数", "教程"]
        let modelTerms = ["模型", "model", "llm", "推理", "上下文", "token"]
        let featureTerms = ["功能", "特性", "能力", "模式", "开关", "组件", "动画", "布局"]

        if experienceTerms.contains(where: lowered.contains) {
            return .init(
                type: "experience_entry",
                summary: localized(
                    zhHans: "用户更像是在找一个可以直接体验、试用或验证能力的入口。",
                    en: "The user is most likely looking for a place to try or validate the experience directly.",
                    languageCode: languageCode
                ),
                actionGoal: localized(
                    zhHans: "优先返回可直接体验或最贴近体验路径的官方入口。",
                    en: "Prefer the most direct official entry for trying the experience.",
                    languageCode: languageCode
                )
            )
        }

        if officialSourceTerms.contains(where: lowered.contains) {
            return .init(
                type: "official_source",
                summary: localized(
                    zhHans: "用户更像是在确认消息的官方出处或最早发布来源。",
                    en: "The user is likely trying to confirm the original official source.",
                    languageCode: languageCode
                ),
                actionGoal: localized(
                    zhHans: "优先返回官方公告、发布页、更新日志或原始出处。",
                    en: "Prefer the official announcement, release page, changelog, or original source.",
                    languageCode: languageCode
                )
            )
        }

        if docsTerms.contains(where: lowered.contains) {
            return .init(
                type: "documentation",
                summary: localized(
                    zhHans: "用户更像是在找功能说明、接入方式或参数解释。",
                    en: "The user is likely looking for docs, integration guidance, or parameter details.",
                    languageCode: languageCode
                ),
                actionGoal: localized(
                    zhHans: "优先返回官方文档页、说明页或开发者入口。",
                    en: "Prefer the official docs page, explanation page, or developer entry.",
                    languageCode: languageCode
                )
            )
        }

        if modelTerms.contains(where: lowered.contains) {
            return .init(
                type: "model_lookup",
                summary: localized(
                    zhHans: "用户更像是在找某个具体模型或模型能力说明。",
                    en: "The user is likely looking for a specific model or its capability page.",
                    languageCode: languageCode
                ),
                actionGoal: localized(
                    zhHans: "优先返回模型页、模型介绍页或体验入口。",
                    en: "Prefer the model page, model overview, or try-it entry.",
                    languageCode: languageCode
                )
            )
        }

        if featureTerms.contains(where: lowered.contains) {
            return .init(
                type: "feature_lookup",
                summary: localized(
                    zhHans: "用户更像是在找某个具体功能或特性的说明与入口。",
                    en: "The user is likely looking for a specific feature and the best place to open it.",
                    languageCode: languageCode
                ),
                actionGoal: localized(
                    zhHans: "优先返回功能页、对应产品页或文档页。",
                    en: "Prefer the feature page, relevant product page, or docs page.",
                    languageCode: languageCode
                )
            )
        }

        return .init(
            type: "product_lookup",
            summary: localized(
                zhHans: "用户更像是在找句子里提到的产品、服务或项目本身。",
                en: "The user is most likely trying to reach the actual product, service, or project mentioned in the text.",
                languageCode: languageCode
            ),
            actionGoal: localized(
                zhHans: "优先返回最值得直接打开的产品主入口。",
                en: "Prefer the most useful main entry to open directly.",
                languageCode: languageCode
            )
        )
    }

    static func buildPlan(for text: String, languageCode: String) -> TracePlanDescriptor {
        let intent = inferIntent(for: text, languageCode: languageCode)
        if let explicitURL = explicitURL(in: text) {
            let host = explicitURL.host?.replacingOccurrences(of: "www.", with: "") ?? explicitURL.absoluteString
            return .init(
                intent: intent,
                primaryEntityName: host,
                entityType: "link",
                whyThis: localized(
                    zhHans: "原文里已经直接出现了可打开链接，优先把它当作主目标入口。",
                    en: "The selection already contains a directly openable link, so it becomes the primary target entry.",
                    languageCode: languageCode
                ),
                ownerHints: [],
                searchQueries: [explicitURL.absoluteString]
            )
        }

        let candidateNames = extractCandidateNames(from: text)
        guard let primaryName = choosePrimaryCandidate(from: text, candidates: candidateNames) else {
            let fallbackQuery = searchQuery(for: text, languageCode: languageCode)
            let fallbackName = preferredExcerpt(from: normalizedSearchText(text))
            return .init(
                intent: intent,
                primaryEntityName: fallbackName.isEmpty ? fallbackQuery : fallbackName,
                entityType: "link",
                whyThis: localized(
                    zhHans: "没有识别出稳定实体，退化为围绕原句核心内容去定位最相关入口。",
                    en: "No stable entity was detected, so the plan falls back to resolving the most relevant entry from the key claim.",
                    languageCode: languageCode
                ),
                ownerHints: [],
                searchQueries: [fallbackQuery]
            )
        }

        let entityType = guessEntityType(in: text, name: primaryName)
        let ownerHints = organizationHints(in: text, primaryName: primaryName)
        return .init(
            intent: intent,
            primaryEntityName: primaryName,
            entityType: entityType,
            whyThis: localized(
                zhHans: "按上下文里最像主目标实体的名称线索来定位入口。",
                en: "Resolve the entry using the name clue that most strongly looks like the main target entity in context.",
                languageCode: languageCode
            ),
            ownerHints: ownerHints,
            searchQueries: composeQueries(
                for: primaryName,
                entityType: entityType,
                ownerHints: ownerHints,
                text: text,
                intentType: intent.type
            )
        )
    }

    static func composePlan(
        primaryEntityName: String,
        entityType: String,
        whyThis: String,
        ownerHints: [String],
        intent: TraceIntentDescriptor,
        text: String
    ) -> TracePlanDescriptor {
        .init(
            intent: intent,
            primaryEntityName: primaryEntityName,
            entityType: entityType,
            whyThis: whyThis,
            ownerHints: ownerHints,
            searchQueries: composeQueries(
                for: primaryEntityName,
                entityType: entityType,
                ownerHints: ownerHints,
                text: text,
                intentType: intent.type
            )
        )
    }

    static func rankSources(_ sources: [SourceRecord], plan: TracePlanDescriptor) -> [SourceRecord] {
        sources.sorted {
            scoreSource($0, plan: plan) > scoreSource($1, plan: plan)
        }
    }

    static func searchQuery(for text: String, languageCode: String) -> String {
        let normalized = normalizedSearchText(text)
        guard normalized.count > 80 else { return normalized }

        let excerpt = preferredExcerpt(from: normalized)
        let keywordSection = keywordSuffix(from: normalized, languageCode: languageCode)
        if keywordSection.isEmpty {
            return "\"\(excerpt)\""
        }
        return "\"\(excerpt)\" \(keywordSection)"
    }

    private static func explicitURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first
    }

    private static func extractCandidateNames(from text: String) -> [String] {
        var names: [String] = []

        func appendCandidate(_ raw: String) {
            let compact = raw
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
            guard !compact.isEmpty else { return }

            // Mirror the old gateway behavior for mixed Chinese/Latin phrases:
            // when a long narrative wrapper contains a concrete latin product token,
            // keep the product token instead of the whole mixed sentence fragment.
            if compact.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil,
               compact.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil {
                let latinTokens = matches(of: #"[A-Za-z][A-Za-z0-9.+-]{2,24}"#, in: compact)
                if !latinTokens.isEmpty,
                   any(of: ["出了", "推出", "发布", "上线", "免费", "体验", "试用", "模型", "功能", "入口", "页面"], in: compact) {
                    for token in latinTokens {
                        let normalizedToken = normalizedEntityName(token)
                        guard !normalizedToken.isEmpty,
                              !genericEntityStoplist.contains(normalizedToken),
                              looksLikeEntityName(token) else {
                            continue
                        }
                        names.append(token)
                    }
                    return
                }
            }

            let normalized = normalizedEntityName(compact)
            guard !normalized.isEmpty, !genericEntityStoplist.contains(normalized) else { return }
            if looksLikeEntityName(compact) {
                names.append(compact)
            }
        }

        let patterns = [
            #"[\"'「《](.{2,40}?)[\"'」》]"#,
            #"\b[A-Z][A-Za-z0-9.+-]{1,40}(?:\s+[A-Z0-9][A-Za-z0-9.+-]{1,24}){0,3}\b"#,
            #"(?<![A-Za-z0-9])[A-Z][A-Za-z0-9]{2,24}(?:[A-Z][A-Za-z0-9]{1,24})*(?![A-Za-z0-9])"#,
            #"(?<![A-Za-z0-9-])[a-z][a-z0-9-]{2,24}(?![A-Za-z0-9-])"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                let targetRange: NSRange
                if match.numberOfRanges > 1 {
                    targetRange = match.range(at: 1)
                } else {
                    targetRange = match.range
                }
                guard let range = Range(targetRange, in: text) else { continue }
                appendCandidate(String(text[range]))
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"[\u4e00-\u9fffA-Za-z0-9]{2,24}(?=(产品|社交网络|平台|网站|工具|模型|应用|公司|项目|仓库))"#) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                appendCandidate(String(text[range]))
            }
        }

        var deduped: [String] = []
        var seen: Set<String> = []
        for name in names {
            let normalized = normalizedEntityName(name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduped.append(name)
        }
        return deduped
    }

    private static func choosePrimaryCandidate(from text: String, candidates: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        let scored = candidates.map { name -> (Double, String) in
            (scoreCandidate(name, in: text), name)
        }
        return scored.max(by: { $0.0 < $1.0 })?.1
    }

    private static func scoreCandidate(_ name: String, in text: String) -> Double {
        let normalized = normalizedEntityName(name)
        let loweredText = text.lowercased()
        let loweredName = name.lowercased()
        let index = loweredText.range(of: loweredName)?.lowerBound
        let context: String
        if let index {
            let start = text.index(index, offsetBy: -min(18, text.distance(from: text.startIndex, to: index)), limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(index, offsetBy: min(name.count + 18, text.distance(from: index, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
            context = text[start..<end].lowercased()
        } else {
            context = loweredText
        }

        var score = Double(normalized.count) / 12.0
        if any(of: ["产品", "社交网络", "平台", "工具", "模型", "应用", "网站", "仓库", "github"], in: context) {
            score += 3
        }
        if any(of: ["收购", "acquire", "acquired", "推出", "发布", "上线"], in: context) {
            score += 1.2
        }
        if any(of: ["官宣", "宣布", "内测", "公测", "灰度", "发布会"], in: context) {
            score += 2.2
        }
        if any(of: ["基于", "based on", "兼容", "支持"], in: context) {
            score -= 1.4
        }
        if commonEntityStoplist.contains(name) {
            score -= 1.5
        }
        if name.range(of: #"[A-Z]"#, options: .regularExpression) != nil {
            score += 1
        }
        let occurrences = loweredText.components(separatedBy: loweredName).count - 1
        if occurrences >= 2 {
            score += min(3, Double(occurrences - 1) * 1.2)
        }
        return score
    }

    private static func guessEntityType(in text: String, name: String) -> String {
        let lowered = text.lowercased()
        let context = lowered
        if name.contains("http://") || name.contains("https://") {
            return "link"
        }
        if any(of: ["模型", "model"], in: context) {
            return "model"
        }
        if any(of: ["文档", "docs", "api"], in: context) {
            return "website"
        }
        if any(of: ["仓库", "github", "repo"], in: context) {
            return "repo"
        }
        if any(of: ["应用", "app"], in: context) {
            return "app"
        }
        return name.range(of: #"[A-Z]"#, options: .regularExpression) != nil ? "product" : "company"
    }

    private static func organizationHints(in text: String, primaryName: String) -> [String] {
        let candidates = extractCandidateNames(from: text)
        let primaryNormalized = normalizedEntityName(primaryName)
        var hints: [String] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let normalized = normalizedEntityName(candidate)
            guard normalized != primaryNormalized,
                  !normalized.isEmpty,
                  !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            hints.append(candidate)
        }
        return Array(hints.prefix(3))
    }

    private static func composeQueries(
        for entityName: String,
        entityType: String,
        ownerHints: [String],
        text: String,
        intentType: String
    ) -> [String] {
        var queries: [String] = []

        for owner in ownerHints.prefix(2) {
            queries.append("\(owner) \(entityName) 官网")
            queries.append("\(owner) \(entityName) official")
        }

        queries.append(entityName)
        queries.append("\"\(entityName)\"")

        switch entityType {
        case "repo":
            queries.append("\(entityName) github")
            queries.append("\(entityName) repository")
        case "model":
            queries.append("\(entityName) model")
            queries.append("\(entityName) official")
        default:
            queries.append("\(entityName) 官网")
            queries.append("\(entityName) official site")
        }

        switch intentType {
        case "experience_entry":
            queries.append("\(entityName) 免费体验")
            queries.append("\(entityName) playground")
        case "documentation":
            queries.append("\(entityName) docs")
            queries.append("\(entityName) 文档")
        case "official_source":
            queries.append("\(entityName) 官方公告")
            queries.append("\(entityName) changelog")
        case "model_lookup":
            queries.append("\(entityName) 模型")
            queries.append("\(entityName) playground")
        case "feature_lookup":
            queries.append("\(entityName) 功能")
            queries.append("\(entityName) feature")
        default:
            break
        }

        let contextualTokens = significantTokens(from: text).prefix(2)
        for token in contextualTokens {
            queries.append("\(entityName) \(token)")
        }

        var deduped: [String] = []
        var seen: Set<String> = []
        for query in queries {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduped.append(query)
        }
        return Array(deduped.prefix(4))
    }

    private static func scoreSource(_ source: SourceRecord, plan: TracePlanDescriptor) -> Double {
        var score = 0.0
        let entity = normalizedEntityName(plan.primaryEntityName)
        let titleAndSnippet = normalizedEntityName(source.title + " " + source.snippet)
        let domain = normalizedEntityName(domain(of: source.url))
        let path = URL(string: source.url)?.path.lowercased() ?? "/"

        if !entity.isEmpty, titleAndSnippet.contains(entity) {
            score += 5
        }
        if !entity.isEmpty, domain.contains(entity) {
            score += 6
        }
        if source.isOfficial == true {
            score += 4
        }
        if referenceDomains.contains(where: { domain.contains(normalizedEntityName($0)) }) {
            score += 1.5
        }
        if newsDomains.contains(where: { domain.contains(normalizedEntityName($0)) }) {
            score -= 3
        }
        if ["/", ""].contains(path) {
            score += 1
        }
        if any(of: ["/docs", "/doc", "/help", "/guide", "/api", "/reference"], in: path),
           plan.intent.type == "documentation" {
            score += 5
        }
        if any(of: ["/demo", "/playground", "/try", "/free", "/preview", "/labs", "/studio"], in: path),
           plan.intent.type == "experience_entry" {
            score += 5.5
        }
        if any(of: ["/blog", "/news", "/changelog", "/release", "/releases", "/announcements", "/post"], in: path),
           plan.intent.type == "official_source" {
            score += 4.6
        }
        if plan.ownerHints.contains(where: { hint in
            let normalizedHint = normalizedEntityName(hint)
            return !normalizedHint.isEmpty && (titleAndSnippet.contains(normalizedHint) || domain.contains(normalizedHint))
        }) {
            score += 3
        }
        return score
    }

    private static func normalizedEntityName(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private static func looksLikeEntityName(_ candidate: String) -> Bool {
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.range(of: #"[，。；：！？,.;:!?]"#, options: .regularExpression) != nil {
            return false
        }
        if text.count > 20, text.range(of: #"[A-Za-z0-9]"#, options: .regularExpression) == nil {
            return false
        }
        if text.split(separator: " ").count > 5 {
            return false
        }
        if ["帮我", "给我", "发句指令", "传给我", "即可", "自动操作", "远程操控"].contains(where: text.contains) {
            return false
        }
        return true
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func domain(of rawURL: String) -> String {
        URL(string: rawURL)?.host?.lowercased() ?? ""
    }

    private static func any(of needles: [String], in haystack: String) -> Bool {
        needles.contains(where: haystack.contains)
    }

    package static func searchResults(from html: String, query: String, limit: Int) -> [SourceRecord] {
        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)

        var results: [SourceRecord] = []
        var seenURLs: Set<String> = []

        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let rawHref = htmlUnescaped(String(html[hrefRange]))
            guard let url = normalizedSearchResultURL(from: rawHref) else { continue }
            guard seenURLs.insert(url.absoluteString.lowercased()).inserted else { continue }

            let title = compactText(String(html[titleRange]), limit: 120)
            let afterAnchor = String(html[Range(match.range, in: html)!])
            let searchWindowStart = html.distance(from: html.startIndex, to: Range(match.range, in: html)!.upperBound)
            let searchWindowEnd = min(html.count, searchWindowStart + 1200)
            let windowStartIndex = html.index(html.startIndex, offsetBy: searchWindowStart)
            let windowEndIndex = html.index(html.startIndex, offsetBy: searchWindowEnd)
            let trailingHTML = String(html[windowStartIndex..<windowEndIndex])
            let snippet = snippetText(from: trailingHTML)

            results.append(
                SourceRecord(
                    title: title.isEmpty ? url.absoluteString : title,
                    url: url.absoluteString,
                    snippet: snippet,
                    publishedAt: nil,
                    sourceType: "web",
                    isOfficial: isLikelyOfficial(url: url, title: title, query: query)
                )
            )

            if results.count >= limit {
                break
            }

            _ = afterAnchor
        }

        return results
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredExcerpt(from text: String) -> String {
        let separators = CharacterSet(charactersIn: "\n。！？!?；;")
        let sentences = text.components(separatedBy: separators)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^[#>*\-\d.\)\s]+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }

        let candidate = sentences.first(where: { $0.count >= 18 }) ?? sentences.first ?? text
        let maxLength = candidate.contains { "\u{4E00}" <= $0 && $0 <= "\u{9FFF}" } ? 72 : 120
        guard candidate.count > maxLength else { return candidate }
        let index = candidate.index(candidate.startIndex, offsetBy: maxLength)
        return String(candidate[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keywordSuffix(from text: String, languageCode: String) -> String {
        let tokens = significantTokens(from: text).prefix(3)
        let joinedTokens = tokens.joined(separator: " ")
        guard !joinedTokens.isEmpty else { return "" }
        if AppLanguage.from(languageCode: languageCode) == .english {
            return joinedTokens
        }
        return joinedTokens + " 官网 官方 原文"
    }

    private static func normalizedSearchResultURL(from href: String) -> URL? {
        var rawHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHref.isEmpty else { return nil }

        if rawHref.hasPrefix("//") {
            rawHref = "https:" + rawHref
        } else if rawHref.hasPrefix("/") {
            rawHref = URL(string: rawHref, relativeTo: searchResultBaseURL)?.absoluteURL.absoluteString ?? rawHref
        }

        guard var url = URL(string: rawHref) else { return nil }

        if let host = url.host?.lowercased(), host.contains("duckduckgo.com"),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let redirectValue = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let redirectURL = URL(string: redirectValue.removingPercentEncoding ?? redirectValue) {
            url = redirectURL
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        return url
    }

    private static func isLikelyOfficial(url: URL, title: String, query: String) -> Bool? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if blockedOfficialHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return false
        }

        let normalizedHost = host.replacingOccurrences(of: "www.", with: "")
        let hostCore = normalizedHost.components(separatedBy: ".").dropLast().joined(separator: ".")
        let queryTokens = significantTokens(from: query)

        if queryTokens.contains(where: { hostCore.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let lowerTitle = title.lowercased()
        if lowerTitle.contains("official") || title.contains("官网") || title.contains("官方") {
            return true
        }

        return nil
    }

    private static func significantTokens(from text: String) -> [String] {
        let pattern = #"[A-Za-z][A-Za-z0-9.+-]{2,24}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var tokens: [String] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range]).lowercased()
            guard seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        return tokens
    }

    private static func snippetText(from html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"class="result__snippet"[^>]*>(.*?)</"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ""
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange),
              let range = Range(match.range(at: 1), in: html) else {
            return ""
        }
        return compactText(String(html[range]), limit: 220)
    }

    private static func compactText(_ htmlFragment: String, limit: Int) -> String {
        let noTags = htmlFragment.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = htmlUnescaped(noTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard decoded.count > limit else { return decoded }
        let index = decoded.index(decoded.startIndex, offsetBy: limit)
        return decoded[..<index].trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func htmlUnescaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }
}

package enum ScheduleRuntimeSupport {
    private static let prefixPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:请|麻烦|帮我|帮忙|提醒我|提醒一下|提醒|记得|别忘了|定个|定一下|安排一下|安排|创建|建立|新增|添加|设置|设个|我想|我要|想|要|需要|在|于|到|把)\s*"#,
        options: []
    )
    private static let relativeOffsetPattern = try! NSRegularExpression(
        pattern: #"(半小时后)|(\d+)\s*(分钟|分|小时|时|天)后"#,
        options: [.caseInsensitive]
    )

    static func fallbackSummary(languageCode: String) -> String {
        AppLanguage.from(languageCode: languageCode) == .english
            ? "No time-related content detected"
            : "未识别到时间相关内容"
    }

    static func looksTimeRelatedText(_ text: String) -> Bool {
        let lower = text.lowercased()
        let timeTerms = [
            "提醒", "日程", "时间", "预约", "会议", "开会", "截止", "deadline", "约", "打卡", "签到",
            "面试", "出发", "航班", "火车", "高铁", "明天", "后天", "今天", "今晚", "明早",
            "上午", "下午", "晚上", "周一", "周二", "周三", "周四", "周五", "周六", "周日", "周天"
        ]
        if timeTerms.contains(where: lower.contains) {
            return true
        }
        return text.range(
            of: #"\d{1,2}[:：]\d{2}|\d+[点号日月时分]|周[一二三四五六日天]"#,
            options: .regularExpression
        ) != nil
    }

    package static func localIntents(from text: String, now: Date = Date()) -> [CalendarEventIntent] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }

        let segments = segmentText(text)
        let isoDate = DateFormatter()
        isoDate.locale = Locale(identifier: "en_US_POSIX")
        isoDate.timeZone = .current
        isoDate.dateFormat = "yyyy-MM-dd"

        let isoTime = DateFormatter()
        isoTime.locale = Locale(identifier: "en_US_POSIX")
        isoTime.timeZone = .current
        isoTime.dateFormat = "HH:mm"

        var intents: [CalendarEventIntent] = []
        var seen: Set<String> = []

        for segment in segments {
            for relative in relativeMatches(in: segment, now: now) {
                let matchedText = relative.matchedText
                let title = extractedTitle(from: segment, removing: matchedText)
                let resolvedTitle = title.isEmpty ? defaultTitle(for: segment) : title
                let dateText = isoDate.string(from: relative.date)
                let timeText = isoTime.string(from: relative.date)
                let dedupKey = [resolvedTitle, dateText, timeText, "false"].joined(separator: "|")
                guard seen.insert(dedupKey).inserted else { continue }

                intents.append(
                    CalendarEventIntent(
                        title: resolvedTitle,
                        date: dateText,
                        time: timeText,
                        endTime: nil,
                        allDay: false,
                        durationMinutes: nil,
                        reminderMinutes: recommendedReminderMinutes(until: relative.date.timeIntervalSince(now)),
                        notes: segment,
                        sourceText: segment,
                        timeText: matchedText,
                        confidence: 0.9,
                        needsConfirmation: false,
                        missingFields: nil
                    )
                )
            }

            let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
            for match in detector.matches(in: segment, options: [], range: range) {
                guard let date = match.date else { continue }
                guard date.timeIntervalSince(now.addingTimeInterval(-86400 * 365 * 5)) > 0 else { continue }
                guard let matchedRange = Range(match.range, in: segment) else { continue }
                let matchedText = String(segment[matchedRange])
                let title = extractedTitle(from: segment, removing: matchedText)
                let explicitTime = hasExplicitTime(in: matchedText, segment: segment)
                let durationMinutes = match.duration > 0 ? Int(match.duration / 60) : nil
                let endTime = durationMinutes.map { isoTime.string(from: date.addingTimeInterval(Double($0) * 60)) }
                let allDay = !explicitTime
                let resolvedTitle = title.isEmpty ? defaultTitle(for: segment) : title
                let dateText = isoDate.string(from: date)
                let timeText = explicitTime ? isoTime.string(from: date) : nil
                let dedupKey = [resolvedTitle, dateText, timeText ?? "", String(allDay)].joined(separator: "|")
                guard seen.insert(dedupKey).inserted else { continue }

                intents.append(
                    CalendarEventIntent(
                        title: resolvedTitle,
                        date: dateText,
                        time: timeText,
                        endTime: endTime,
                        allDay: allDay,
                        durationMinutes: durationMinutes,
                        reminderMinutes: allDay ? 480 : 15,
                        notes: segment,
                        sourceText: segment,
                        timeText: matchedText,
                        confidence: 0.84,
                        needsConfirmation: false,
                        missingFields: nil
                    )
                )
            }
        }

        return intents.sorted {
            ($0.resolvedStartDate ?? .distantFuture) < ($1.resolvedStartDate ?? .distantFuture)
        }
    }

    static func summary(for intents: [CalendarEventIntent], languageCode: String) -> String {
        guard !intents.isEmpty else { return fallbackSummary(languageCode: languageCode) }
        if AppLanguage.from(languageCode: languageCode) == .english {
            return "Detected \(intents.count) schedule item(s). Click a card to create the reminder."
        }
        return "识别到 \(intents.count) 个日程，点击卡片创建提醒"
    }

    package static func actionCards(from intents: [CalendarEventIntent], languageCode: String) -> [SkillResultCard] {
        intents.prefix(4).enumerated().map { index, intent in
            let encoder = JSONEncoder()
            let intentJSON = (try? encoder.encode(intent))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            return SkillResultCard(
                id: "action_card_calendar_\(index)",
                kind: IntentKind.calendarEvent.rawValue,
                title: intent.title,
                badges: intent.needsConfirmation == true
                    ? [localized(zhHans: "待补充", en: "Needs details", languageCode: languageCode)]
                    : nil,
                subtitle: nil,
                description: "\(intent.displayScheduleSummary) · \(intent.reminderSummary)",
                action: SkillResultAction(
                    type: .createCalendarEvent,
                    label: intent.needsConfirmation == true
                        ? localized(zhHans: "打开日历补充", en: "Open Calendar Draft", languageCode: languageCode)
                        : localized(zhHans: "创建日历事件", en: "Create Calendar Event", languageCode: languageCode),
                    value: intentJSON
                ),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: nil
            )
        }
    }

    private static func segmentText(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "礼拜", with: "周")
            .replacingOccurrences(of: "星期天", with: "星期日")
            .replacingOccurrences(of: "周天", with: "周日")
            .components(separatedBy: CharacterSet(charactersIn: "，；;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractedTitle(from segment: String, removing matchedText: String) -> String {
        var title = segment.replacingOccurrences(of: matchedText, with: " ")
        var previous = ""
        while previous != title {
            previous = title
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            title = prefixPattern.stringByReplacingMatches(in: title, range: range, withTemplate: "")
        }
        title = title.replacingOccurrences(
            of: #"(今天|明天|后天|大后天|今晚|今早|明早|明晚|上午|下午|晚上|凌晨|中午|傍晚|周[一二三四五六日天]|星期[一二三四五六日天]|\d{1,2}[:：]\d{2}|\d{1,2}\s*点(?:半|\d{1,2}\s*分?)?)"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(of: #"(?:提醒|日程|calendar|event)\b"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if title.hasPrefix("开"), title.count >= 4 {
            title.removeFirst()
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasExplicitTime(in matchedText: String, segment: String) -> Bool {
        let text = matchedText + " " + segment
        return text.range(
            of: #"(上午|下午|晚上|凌晨|中午|傍晚|今晚|今早|明早|明晚|\d{1,2}[:：]\d{2}|\d{1,2}\s*点(?:半|\d{1,2}\s*分?)?|am|pm)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func defaultTitle(for segment: String) -> String {
        if segment.contains("提醒") || segment.contains("记得") || segment.contains("别忘") {
            return "提醒事项"
        }
        let compact = segment.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "Reminder" }
        return compact.count > 24 ? String(compact.prefix(24)) : compact
    }

    private static func relativeMatches(in text: String, now: Date) -> [(matchedText: String, date: Date)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return relativeOffsetPattern.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchedRange = Range(match.range, in: text) else { return nil }
            let matchedText = String(text[matchedRange])

            if match.range(at: 1).location != NSNotFound {
                return (matchedText, now.addingTimeInterval(30 * 60))
            }

            guard let valueRange = Range(match.range(at: 2), in: text),
                  let unitRange = Range(match.range(at: 3), in: text),
                  let value = Int(text[valueRange]) else {
                return nil
            }

            let unit = String(text[unitRange]).lowercased()
            let interval: TimeInterval
            switch unit {
            case "分钟", "分":
                interval = TimeInterval(value * 60)
            case "小时", "时":
                interval = TimeInterval(value * 3600)
            case "天":
                interval = TimeInterval(value * 86_400)
            default:
                return nil
            }
            return (matchedText, now.addingTimeInterval(interval))
        }
    }

    private static func recommendedReminderMinutes(until interval: TimeInterval) -> Int {
        let totalMinutes = max(0, Int(interval / 60))
        switch totalMinutes {
        case 0...10:
            return 0
        case 11...30:
            return 5
        case 31...90:
            return 10
        default:
            return 15
        }
    }

    private static func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }
}
