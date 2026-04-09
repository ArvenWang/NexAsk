import Foundation

enum ResultDeliveryPolicy {
    static func supportsMessageWriteback(bundleID: String?) -> Bool {
        SourceAppPolicy.supportsMessageWriteback(bundleID: bundleID)
    }

    static func writebackPayload(
        for resultEnvelope: SkillResultEnvelope,
        definition: SkillDefinition?,
        displayText: String,
        sourceInteractionContext: SourceInteractionContext
    ) -> String? {
        guard sourceInteractionContext.supportsMessageWriteback else {
            return nil
        }

        let skillID = definition?.skillID ?? resultEnvelope.skillID
        switch skillID {
        case "reply":
            return normalizedMessagePayload(
                resultEnvelope.replacePayload ?? resultEnvelope.copyPayload ?? displayText,
                maxCharacters: 320,
                maxLines: 6
            )
        case "explain":
            return normalizedMessagePayload(
                resultEnvelope.body ?? resultEnvelope.summary ?? displayText,
                maxCharacters: 220,
                maxLines: 4
            )
        case "trace":
            return normalizedMessagePayload(
                traceMessagePayload(from: resultEnvelope, displayText: displayText),
                maxCharacters: 320,
                maxLines: 6
            )
        default:
            return nil
        }
    }

    private static func traceMessagePayload(
        from resultEnvelope: SkillResultEnvelope,
        displayText: String
    ) -> String? {
        let summary = (resultEnvelope.summary ?? resultEnvelope.body ?? displayText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryURL = resolvedTracePrimaryURL(from: resultEnvelope)?
            .absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        if !summary.isEmpty {
            lines.append(summary)
        }
        if let primaryURL, !primaryURL.isEmpty {
            lines.append(primaryURL)
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func resolvedTracePrimaryURL(from resultEnvelope: SkillResultEnvelope) -> URL? {
        if resultEnvelope.primaryAction?.type == .openURL,
           let value = resultEnvelope.primaryAction?.value,
           let url = URL(string: value) {
            return url
        }

        if let cards = resultEnvelope.cards,
           let cardURL = cards.compactMap({ card -> URL? in
               guard card.action?.type == .openURL,
                     let value = card.action?.value else {
                   return nil
               }
               return URL(string: value)
           }).first {
            return cardURL
        }

        guard let artifactItems = resultEnvelope.artifacts?
            .first(where: { $0.kind == "entity_list" || $0.kind == "source_list" })?
            .items else {
            return nil
        }

        return artifactItems.compactMap { item in
            guard let value = item["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            return URL(string: value)
        }.first
    }

    private static func normalizedMessagePayload(
        _ payload: String?,
        maxCharacters: Int,
        maxLines: Int
    ) -> String? {
        guard let payload else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty, lines.count <= maxLines else { return nil }

        let collapsed = lines.joined(separator: "\n")
        guard collapsed.count <= maxCharacters else { return nil }
        return collapsed
    }
}
