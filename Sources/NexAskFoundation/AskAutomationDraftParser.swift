import Foundation

package final class AskAutomationDraftParser {
    package static let shared = AskAutomationDraftParser()

    private static let relativeOffsetPattern = #"(半小时后)|(\d+)\s*(分钟|分|小时|时|天)后|in\s+(\d+)\s+(minutes?|hours?|days?)|after\s+(\d+)\s+(minutes?|hours?|days?)"#

    private let weekdayMap: [String: Int] = [
        "周日": 1, "周天": 1, "星期天": 1, "星期日": 1, "sunday": 1,
        "周一": 2, "星期一": 2, "monday": 2,
        "周二": 3, "星期二": 3, "tuesday": 3,
        "周三": 4, "星期三": 4, "wednesday": 4,
        "周四": 5, "星期四": 5, "thursday": 5,
        "周五": 6, "星期五": 6, "friday": 6,
        "周六": 7, "星期六": 7, "saturday": 7
    ]

    package init() {}

    package func detectsAutomationIntent(in text: String) -> Bool {
        let normalized = normalize(text)
        let keywords = [
            "每天", "每周", "每月", "每隔", "定时", "定期", "周期性", "以后都这样做", "以后", "监控", "跟踪", "定时检查", "定时汇总",
            "every day", "every week", "every month", "every ", "monitor", "track", "recurring", "schedule", "periodic"
        ]
        if keywords.contains(where: normalized.contains) {
            return true
        }
        if firstFullMatch(in: normalized, pattern: Self.relativeOffsetPattern) != nil {
            return true
        }
        return normalized.range(of: #"今晚\s*\d|明天\s*\d|tomorrow\s+at|tonight\s+at"#, options: .regularExpression) != nil
    }

    package func parse(_ spec: String, now: Date = Date(), workspaceRoot: String? = nil) -> AskAutomationDraft? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let parsed = parseTrigger(in: trimmed, now: now) else {
            return nil
        }

        let normalizedTaskPrompt = normalizedPrompt(from: trimmed, removing: parsed.matchedPhrase)
        let toolDomains = detectedToolDomains(for: normalizedTaskPrompt)
        let allowLightWrites = toolDomains.contains("knowledge") || toolDomains.contains("calendar")
        let title = preferredTitle(from: normalizedTaskPrompt)
        let riskSummary = preferredRiskSummary(toolDomains: toolDomains, allowLightWrites: allowLightWrites)

        return AskAutomationDraft(
            id: UUID().uuidString.lowercased(),
            title: title,
            naturalLanguageSpec: trimmed,
            normalizedTaskPrompt: normalizedTaskPrompt,
            workspaceRoot: workspaceRoot,
            trigger: parsed.trigger,
            toolPolicy: .default,
            delivery: .default,
            keyToolDomains: toolDomains,
            riskSummary: riskSummary,
            allowLightWrites: allowLightWrites,
            createdAt: now
        )
    }

    private func parseTrigger(in text: String, now: Date) -> (trigger: AskAutomationTrigger, matchedPhrase: String)? {
        let normalized = normalize(text)

        if let intervalPhrase = firstFullMatch(in: normalized, pattern: #"每隔\s*(\d+)\s*小时|every\s+(\d+)\s+hours?"#),
           let hours = firstInteger(in: intervalPhrase), hours > 0 {
            return (
                AskAutomationTrigger(kind: .everyNHours, intervalHours: hours),
                intervalPhrase
            )
        }

        if let weeklyPhrase = firstFullMatch(in: normalized, pattern: #"每周[一二三四五六日天]|星期[一二三四五六日天]|(?:every|each)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#),
           let weekday = weekdayValue(from: weeklyPhrase) {
            let clock = resolvedClockComponents(in: normalized) ?? (9, 0)
            return (
                AskAutomationTrigger(kind: .weekly, hour: clock.hour, minute: clock.minute, weekday: weekday),
                weeklyPhrase
            )
        }

        if let monthlyPhrase = firstFullMatch(in: normalized, pattern: #"每月\s*(\d{1,2})\s*[号日]|on day\s+(\d{1,2})\s+of every month"#),
           let day = firstInteger(in: monthlyPhrase) {
            let clock = resolvedClockComponents(in: normalized) ?? (9, 0)
            return (
                AskAutomationTrigger(kind: .monthlyDay, hour: clock.hour, minute: clock.minute, day: day),
                monthlyPhrase
            )
        }

        if let dailyPhrase = firstFullMatch(in: normalized, pattern: #"每天|daily|every day"#) {
            let clock = resolvedClockComponents(in: normalized) ?? (9, 0)
            return (
                AskAutomationTrigger(kind: .dailyAt, hour: clock.hour, minute: clock.minute),
                dailyPhrase
            )
        }

        if let relativePhrase = firstFullMatch(in: normalized, pattern: Self.relativeOffsetPattern),
           let absoluteDate = resolvedRelativeDate(from: relativePhrase, now: now) {
            return (
                AskAutomationTrigger(kind: .onceAt, absoluteDate: absoluteDate),
                relativePhrase
            )
        }

        if let oncePhrase = firstFullMatch(in: normalized, pattern: #"今晚|今天晚上|明天|tomorrow|tonight|today"#) {
            let clock = resolvedClockComponents(in: normalized) ?? (20, 0)
            let absoluteDate = resolvedAbsoluteDate(keyword: oncePhrase, hour: clock.hour, minute: clock.minute, now: now)
            return (
                AskAutomationTrigger(kind: .onceAt, absoluteDate: absoluteDate),
                oncePhrase
            )
        }

        return nil
    }

    private func normalizedPrompt(from spec: String, removing schedulePhrase: String) -> String {
        var text = spec
        text = replacePattern(schedulePhrase, in: text, with: "", options: [.caseInsensitive, .regularExpression])
        text = stripLeadingSchedulePreamble(from: text)
        text = stripLeadingScheduleFragments(from: text)
        text = stripLeadingSchedulePreamble(from: text)
        text = replacePattern(#"^[，。；;:：\s]+"#, in: text, with: "")
        text = replacePattern(#"[，。；;:：\s]+$"#, in: text, with: "")
        text = replacePattern(#"\s+"#, in: text, with: " ")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    private func stripLeadingSchedulePreamble(from text: String) -> String {
        let patterns = [
            #"^[，。；;:：\s]+"#,
            #"^(以后都这样做|以后|之后|请|帮我|帮忙|定时|定期|周期性|到点后|自动|自动地|后续)\s*"#
        ]
        return applyingLeadingPatterns(patterns, to: text)
    }

    private func stripLeadingScheduleFragments(from text: String) -> String {
        let patterns = [
            #"^(?:每天|daily|every day)\s*"#,
            #"^(?:每周[一二三四五六日天]|星期[一二三四五六日天]|(?:every|each)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\s*"#,
            #"^(?:每月\s*\d{1,2}\s*[号日]|on day\s+\d{1,2}\s+of every month)\s*"#,
            #"^(?:每隔\s*\d+\s*小时|every\s+\d+\s+hours?)\s*"#,
            #"^(?:半小时后|\d+\s*(?:分钟|分|小时|时|天)后|in\s+\d+\s+(?:minutes?|hours?|days?)|after\s+\d+\s+(?:minutes?|hours?|days?))\s*"#,
            #"^(?:今晚|今天晚上|今天|明天|tonight|today|tomorrow)\s*"#,
            #"^(?:(?:凌晨|早上|上午|中午|下午|晚上|今晚|morning|afternoon|evening|night)\s*\d{1,2}(?:(?:\s*[:：]\s*\d{1,2})|\s*点(?:\s*(?:半|\d{1,2}))?)?|\d{1,2}(?:(?:\s*[:：]\s*\d{1,2})|\s*点(?:\s*(?:半|\d{1,2}))?))\s*"#,
            #"^[，。；;:：\s]+"#
        ]
        return applyingLeadingPatterns(patterns, to: text)
    }

    private func applyingLeadingPatterns(_ patterns: [String], to text: String) -> String {
        var current = text
        var previous: String
        repeat {
            previous = current
            for pattern in patterns {
                current = replacePattern(pattern, in: current, with: "", options: [.caseInsensitive, .regularExpression])
            }
        } while current != previous
        return current
    }

    private func replacePattern(
        _ pattern: String,
        in text: String,
        with replacement: String,
        options: String.CompareOptions = [.regularExpression]
    ) -> String {
        guard !pattern.isEmpty else { return text }
        return text.replacingOccurrences(of: pattern, with: replacement, options: options)
    }

    private func detectedToolDomains(for prompt: String) -> [String] {
        let normalized = normalize(prompt)
        var domains: [String] = []

        if containsAny(normalized, terms: ["官网", "网页", "页面", "链接", "url", "website", "site", "browser", "打开", "访问", "搜索", "搜", "查", "open", "visit", "search", "look up"]) {
            domains.append("web")
        }
        if containsAny(normalized, terms: ["知识库", "knowledge", "采集", "collect", "总结到知识库"]) {
            domains.append("knowledge")
        }
        if containsAny(normalized, terms: ["日历", "calendar", "提醒", "reminder"]) {
            domains.append("calendar")
        }
        if containsAny(normalized, terms: ["复制", "写回", "替换", "clipboard", "paste"]) {
            domains.append("writeback")
        }
        if containsAny(normalized, terms: ["文件", "文件夹", "desktop", "downloads", "documents", "finder", "path", "pdf"]) {
            domains.append("files")
        }
        if containsAny(normalized, terms: ["项目", "仓库", "repo", "repository", "workspace", "代码", "code", "git", "diff", "patch", "shell", "命令"]) {
            domains.append("workspace")
        }

        if domains.isEmpty {
            domains.append("agent")
        }

        return Array(Set(domains)).sorted()
    }

    private func preferredRiskSummary(toolDomains: [String], allowLightWrites: Bool) -> String {
        let base = allowLightWrites
            ? AskRuntimeLocalization.text(
                zhHans: "允许轻写操作，例如知识库写入或创建日历项；高风险动作会被阻止并转成待处理项。",
                en: "Allows light writes such as knowledge-base writes or calendar creation; high-risk actions are blocked and turned into inbox items."
            )
            : AskRuntimeLocalization.text(
                zhHans: "默认只做读取、检索和整理；高风险动作会被阻止并转成待处理项。",
                en: "Defaults to reading, lookup, and summarization; high-risk actions are blocked and turned into inbox items."
            )
        if toolDomains.contains("files") {
            return base + " " + AskRuntimeLocalization.text(
                zhHans: "文件改动不会在后台静默执行。",
                en: "File mutations are never executed silently in the background."
            )
        }
        if toolDomains.contains("workspace") {
            return base + " " + AskRuntimeLocalization.text(
                zhHans: "工作区写操作、shell 命令和 patch 落地不会在后台自动执行。",
                en: "Workspace writes, shell commands, and patch application are never executed automatically in the background."
            )
        }
        return base
    }

    private func preferredTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AskRuntimeLocalization.text(zhHans: "新的定时任务", en: "New automation")
        }
        if trimmed.count <= 18 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 18)
        return String(trimmed[..<index]) + "…"
    }

    private func resolvedRelativeDate(from phrase: String, now: Date) -> Date? {
        let normalized = normalize(phrase)
        if normalized.contains("半小时后") {
            return now.addingTimeInterval(30 * 60)
        }

        guard let amount = firstInteger(in: normalized) else {
            return nil
        }

        let seconds: TimeInterval
        if containsAny(normalized, terms: ["分钟后", "分后", "minute", "minutes"]) {
            seconds = TimeInterval(amount * 60)
        } else if containsAny(normalized, terms: ["小时后", "时后", "hour", "hours"]) {
            seconds = TimeInterval(amount * 3600)
        } else if containsAny(normalized, terms: ["天后", "day", "days"]) {
            seconds = TimeInterval(amount * 86_400)
        } else {
            return nil
        }

        return now.addingTimeInterval(seconds)
    }

    private func resolvedAbsoluteDate(keyword: String, hour: Int, minute: Int, now: Date) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .current

        let normalizedKeyword = normalize(keyword)
        let baseDate: Date
        if normalizedKeyword.contains("明天") || normalizedKeyword.contains("tomorrow") {
            baseDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        } else {
            baseDate = now
        }

        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour
        components.minute = minute
        components.second = 0

        let candidate = calendar.date(from: components) ?? now
        if normalizedKeyword.contains("今晚") || normalizedKeyword.contains("today") || normalizedKeyword.contains("今天") {
            if candidate <= now {
                return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86_400)
            }
        }
        return candidate
    }

    private func weekdayValue(from phrase: String) -> Int? {
        let normalized = normalize(phrase)
        for (key, value) in weekdayMap where normalized.contains(normalize(key)) {
            return value
        }
        return nil
    }

    private func resolvedClockComponents(in text: String) -> (hour: Int, minute: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:(凌晨|早上|上午|中午|下午|晚上|今晚|morning|afternoon|evening|night)\s*)?(\d{1,2})(?:\s*[:：]\s*(\d{1,2})|\s*点\s*(半|\d{1,2})?)?"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard let match = matches.last(where: { Range($0.range(at: 2), in: text) != nil }),
              let hourRange = Range(match.range(at: 2), in: text),
              let rawHour = Int(text[hourRange]) else {
            return nil
        }

        let meridiem: String?
        if let range = Range(match.range(at: 1), in: text) {
            meridiem = String(text[range]).lowercased()
        } else {
            meridiem = nil
        }

        var minute = 0
        if let minuteRange = Range(match.range(at: 3), in: text),
           let rawMinute = Int(text[minuteRange]) {
            minute = rawMinute
        } else if let zhMinuteRange = Range(match.range(at: 4), in: text) {
            let token = String(text[zhMinuteRange])
            if token == "半" {
                minute = 30
            } else if let rawMinute = Int(token) {
                minute = rawMinute
            }
        }

        var hour = rawHour
        if let meridiem {
            if ["下午", "晚上", "今晚", "afternoon", "evening", "night"].contains(where: meridiem.contains) {
                if hour < 12 {
                    hour += 12
                }
            } else if ["凌晨"].contains(where: meridiem.contains) && hour == 12 {
                hour = 0
            } else if ["中午"].contains(where: meridiem.contains), hour < 11 {
                hour += 12
            }
        }

        hour = max(0, min(hour, 23))
        minute = max(0, min(minute, 59))
        return (hour, minute)
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            if let groupRange = Range(match.range(at: index), in: text) {
                let group = text[groupRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !group.isEmpty {
                    return group
                }
            }
        }

        return String(text[fullRange])
    }

    private func firstFullMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[fullRange])
    }

    private func firstInteger(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let capture = Range(match.range, in: text) else {
            return nil
        }
        return Int(text[capture])
    }

    private func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains(where: text.contains)
    }
}
