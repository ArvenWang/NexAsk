import Foundation

enum IntentKind: String, Codable {
    case calendarEvent = "calendar_event"
    case reminder = "reminder"
}

enum IntentExtractor {
    private static let calendarTagPattern = try! NSRegularExpression(
        pattern: "<calendar_intent>\\s*(\\{[^}]+\\})\\s*</calendar_intent>",
        options: [.dotMatchesLineSeparators]
    )

    struct ExtractionResult {
        let cleanedText: String
        let calendarIntents: [CalendarEventIntent]
    }

    static func extract(from text: String) -> ExtractionResult {
        var calendarIntents: [CalendarEventIntent] = []
        let range = NSRange(text.startIndex..., in: text)

        let matches = calendarTagPattern.matches(in: text, range: range)
        for match in matches {
            guard let jsonRange = Range(match.range(at: 1), in: text) else { continue }
            let jsonString = String(text[jsonRange])
            guard let data = jsonString.data(using: .utf8) else { continue }
            let decoder = JSONDecoder()
            if let intent = try? decoder.decode(CalendarEventIntent.self, from: data) {
                calendarIntents.append(intent)
            }
        }

        let cleanedText = calendarTagPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return ExtractionResult(
            cleanedText: cleanedText,
            calendarIntents: calendarIntents
        )
    }

    static func actionCards(from intents: [CalendarEventIntent]) -> [SkillResultCard] {
        intents.enumerated().map { index, intent in
            let encoder = JSONEncoder()
            let intentJSON: String
            if let data = try? encoder.encode(intent) {
                intentJSON = String(data: data, encoding: .utf8) ?? "{}"
            } else {
                intentJSON = "{}"
            }

            return SkillResultCard(
                id: "action_card_calendar_\(index)",
                kind: IntentKind.calendarEvent.rawValue,
                title: intent.title,
                badges: nil,
                subtitle: nil,
                description: "\(intent.displayScheduleSummary) · \(intent.reminderSummary)",
                action: SkillResultAction(
                    type: .createCalendarEvent,
                    label: L10n.text(zhHans: "创建日历事件", en: "Create Calendar Event"),
                    value: intentJSON
                ),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: nil
            )
        }
    }
}
