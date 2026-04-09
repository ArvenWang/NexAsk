import Foundation

enum ResultSchemaAdapter {
    static func resultEnvelope(
        for result: ActionResult,
        definition: SkillDefinition?,
        context: SkillExecutionContext? = nil
    ) -> SkillResultEnvelope {
        switch result {
        case .translate(let payload):
            let followups = SkillFollowupResolver.resolve(
                skillID: definition?.skillID ?? "translate",
                envelopeFollowups: nil,
                context: context
            )
            return SkillResultEnvelope(
                schemaVersion: definition?.manifest.schemaVersion ?? "0.1",
                skillID: definition?.skillID ?? "translate",
                resultType: definition?.resultType ?? .plainTextWithReplace,
                summary: L10n.text(zhHans: "翻译完成", en: "Translation complete"),
                body: payload.translatedText,
                primaryAction: SkillResultAction(
                    type: .replaceSelection,
                    label: L10n.text(zhHans: "替换原文", en: "Replace Original"),
                    value: payload.translatedText
                ),
                secondaryActions: [
                    SkillResultAction(type: .copyText, label: L10n.text(zhHans: "复制结果", en: "Copy Result"), value: payload.translatedText)
                ],
                cards: [],
                artifacts: [],
                copyPayload: payload.translatedText,
                replacePayload: payload.translatedText,
                followups: followups,
                metadata: mergedMetadata(
                    base: [
                    "detected_language": payload.detectedLanguage,
                    "target_language": payload.targetLanguage
                    ],
                    context: context
                )
            )

        case .trace(let payload):
            let followups = SkillFollowupResolver.resolve(
                skillID: definition?.skillID ?? "trace",
                envelopeFollowups: nil,
                context: context
            )
            let cards = traceCards(from: payload)
            return SkillResultEnvelope(
                schemaVersion: definition?.manifest.schemaVersion ?? "0.1",
                skillID: definition?.skillID ?? "trace",
                resultType: definition?.resultType ?? .summaryWithCards,
                summary: payload.summary,
                body: payload.summary,
                primaryAction: tracePrimaryAction(from: payload, cards: cards),
                secondaryActions: [
                    SkillResultAction(type: .copyText, label: L10n.text(zhHans: "复制结果", en: "Copy Result"), value: traceCopyPayload(from: payload))
                ],
                cards: cards,
                artifacts: traceArtifacts(from: payload),
                copyPayload: traceCopyPayload(from: payload),
                replacePayload: nil,
                followups: followups,
                metadata: mergedMetadata(
                    base: [
                    "confidence": String(payload.confidence),
                    "timeline_count": String(payload.timeline.count),
                    "source_count": String(payload.sources.count)
                    ],
                    context: context
                )
            )

        case .explain(let payload):
            let followups = SkillFollowupResolver.resolve(
                skillID: definition?.skillID ?? "explain",
                envelopeFollowups: nil,
                context: context
            )
            return SkillResultEnvelope(
                schemaVersion: definition?.manifest.schemaVersion ?? "0.1",
                skillID: definition?.skillID ?? "explain",
                resultType: definition?.resultType ?? .summaryText,
                summary: payload.explanationText,
                body: payload.explanationText,
                primaryAction: nil,
                secondaryActions: [
                    SkillResultAction(type: .copyText, label: L10n.text(zhHans: "复制结果", en: "Copy Result"), value: payload.explanationText)
                ],
                cards: [],
                artifacts: [],
                copyPayload: payload.explanationText,
                replacePayload: nil,
                followups: followups,
                metadata: mergedMetadata(base: [:], context: context)
            )

        case .reply(let payload):
            let followups = SkillFollowupResolver.resolve(
                skillID: definition?.skillID ?? "reply",
                envelopeFollowups: nil,
                context: context
            )
            return SkillResultEnvelope(
                schemaVersion: definition?.manifest.schemaVersion ?? "0.1",
                skillID: definition?.skillID ?? "reply",
                resultType: definition?.resultType ?? .responseText,
                summary: nil,
                body: payload.replyText,
                primaryAction: nil,
                secondaryActions: [
                    SkillResultAction(type: .copyText, label: L10n.text(zhHans: "复制结果", en: "Copy Result"), value: payload.replyText)
                ],
                cards: [],
                artifacts: [],
                copyPayload: payload.replyText,
                replacePayload: nil,
                followups: followups,
                metadata: mergedMetadata(
                    base: [
                    "supports_followup": "false"
                    ],
                    context: context
                )
            )

        case .info(let message):
            let followups = SkillFollowupResolver.resolve(
                skillID: definition?.skillID ?? "info",
                envelopeFollowups: nil,
                context: context
            )
            let copyPayload = definition?.supportsCopy == true ? message : nil
            let replacePayload = definition?.supportsReplace == true ? message : nil
            var metadata = mergedMetadata(base: [:], context: context)
            if definition?.skillSource == .installed {
                metadata["generic_skill"] = "true"
            }
            return SkillResultEnvelope(
                schemaVersion: definition?.manifest.schemaVersion ?? "0.1",
                skillID: definition?.skillID ?? "info",
                resultType: definition?.resultType ?? .plainText,
                summary: message,
                body: message,
                primaryAction: nil,
                secondaryActions: [],
                cards: [],
                artifacts: [],
                copyPayload: copyPayload,
                replacePayload: replacePayload,
                followups: followups,
                metadata: metadata
            )
        }
    }

    static func normalizeEnvelope(
        _ envelope: SkillResultEnvelope,
        definition: SkillDefinition?,
        context: SkillExecutionContext? = nil
    ) -> SkillResultEnvelope {
        let merged = mergedMetadata(base: envelope.metadata ?? [:], context: context)
        let resolvedFollowups = normalizedFollowups(
            from: envelope,
            definition: definition,
            context: context,
            metadata: merged
        )

        return SkillResultEnvelope(
            schemaVersion: envelope.schemaVersion,
            skillID: envelope.skillID,
            resultType: envelope.resultType,
            summary: envelope.summary,
            body: envelope.body,
            primaryAction: envelope.primaryAction,
            secondaryActions: envelope.secondaryActions,
            cards: envelope.cards,
            artifacts: envelope.artifacts,
            copyPayload: envelope.copyPayload,
            replacePayload: envelope.replacePayload,
            followups: resolvedFollowups,
            metadata: merged
        )
    }

    private static func normalizedFollowups(
        from envelope: SkillResultEnvelope,
        definition: SkillDefinition?,
        context: SkillExecutionContext?,
        metadata: [String: String]
    ) -> [SkillFollowup] {
        let skillID = definition?.skillID ?? envelope.skillID
        let depth = context?.followupDepth ?? Int(metadata["followup_depth"] ?? "") ?? 0

        guard depth == 0 else { return [] }
        guard skillID != "reply" else { return [] }

        if let followups = envelope.followups, !followups.isEmpty {
            return SkillFollowupResolver.resolve(
                skillID: skillID,
                envelopeFollowups: followups,
                context: context,
                metadata: metadata
            )
        }

        return SkillFollowupResolver.resolve(
            skillID: skillID,
            envelopeFollowups: nil,
            context: context,
            metadata: metadata
        )
    }

    static func traceSupplementEvent(for entities: [TraceEntity]) -> SkillRuntimeEvent? {
        let cards = traceCards(from: entities)
        guard !cards.isEmpty else { return nil }
        return SkillRuntimeEvent(
            type: .supplement,
            cards: cards,
            artifacts: traceEntityArtifacts(from: entities)
        )
    }

    private static func tracePrimaryAction(from result: TraceResult, cards: [SkillResultCard]) -> SkillResultAction? {
        if let cardAction = cards.first?.action {
            return cardAction
        }
        if let url = result.sources.first?.url, !url.isEmpty {
            return SkillResultAction(type: .openURL, label: L10n.text(zhHans: "打开来源", en: "Open Source"), value: url)
        }
        return nil
    }

    private static func traceCards(from result: TraceResult) -> [SkillResultCard] {
        traceCards(from: resolvedTraceEntities(from: result))
    }

    private static func traceCards(from entities: [TraceEntity]) -> [SkillResultCard] {
        entities.prefix(4).enumerated().map { index, entity in
            let badges = traceBadges(for: entity, index: index)
            return SkillResultCard(
                id: "trace_card_\(index)",
                kind: entity.entityType,
                title: entity.name,
                badges: badges.isEmpty ? nil : badges,
                subtitle: entity.url.isEmpty ? nil : entity.url,
                description: entity.snippet.isEmpty ? nil : entity.snippet,
                action: entity.url.isEmpty
                    ? nil
                    : SkillResultAction(type: .openURL, label: L10n.text(zhHans: "打开", en: "Open"), value: entity.url),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: entity.isOfficial
            )
        }
    }

    private static func traceArtifacts(from result: TraceResult) -> [SkillArtifact] {
        var artifacts: [SkillArtifact] = []

        if !result.timeline.isEmpty {
            artifacts.append(
                SkillArtifact(
                    kind: "timeline",
                    items: result.timeline.map { ["text": $0] }
                )
            )
        }

        if !result.sources.isEmpty {
            artifacts.append(
                SkillArtifact(
                    kind: "source_list",
                    items: result.sources.map { source in
                        [
                            "title": source.title,
                            "url": source.url,
                            "snippet": source.snippet,
                            "published_at": source.publishedAt ?? "",
                            "source_type": source.sourceType ?? "",
                            "is_official": String(source.isOfficial ?? false)
                        ]
                    }
                )
            )
        }

        if let eventSummary = result.eventSummary, !eventSummary.isEmpty {
            artifacts.append(
                SkillArtifact(
                    kind: "event_summary",
                    items: [["text": eventSummary]]
                )
            )
        }

        return artifacts
    }

    private static func traceEntityArtifacts(from entities: [TraceEntity]) -> [SkillArtifact] {
        guard !entities.isEmpty else { return [] }
        return [
            SkillArtifact(
                kind: "entity_list",
                items: entities.map { entity in
                    [
                        "name": entity.name,
                        "entity_type": entity.entityType,
                        "title": entity.title,
                        "url": entity.url,
                        "snippet": entity.snippet,
                        "why_this": entity.whyThis ?? "",
                        "is_official": String(entity.isOfficial ?? false)
                    ]
                }
            )
        ]
    }

    private static func resolvedTraceEntities(from trace: TraceResult) -> [TraceEntity] {
        if let entities = trace.primaryEntities, !entities.isEmpty {
            return entities
        }

        var entities: [TraceEntity] = []
        if let primary = trace.primaryEntity {
            entities.append(primary)
        }
        if let related = trace.relatedEntities {
            entities.append(contentsOf: related.filter { !$0.url.isEmpty })
        }
        return entities
    }

    private static func traceBadges(for entity: TraceEntity, index: Int) -> [String] {
        var badges: [String] = []
        if index == 0 {
            badges.append(L10n.text(zhHans: "主源头", en: "Primary"))
        }
        if entity.isOfficial == true {
            badges.append(L10n.text(zhHans: "官方", en: "Official"))
        }
        return badges
    }

    private static func traceCopyPayload(from trace: TraceResult) -> String {
        var lines: [String] = []

        if let entity = trace.primaryEntity {
            lines.append(L10n.format(zhHans: "主目标：%@", en: "Primary target: %@", entity.name))
            if !entity.title.isEmpty, entity.title != entity.name {
                lines.append(L10n.format(zhHans: "标题：%@", en: "Title: %@", entity.title))
            }
            if !entity.url.isEmpty {
                lines.append(L10n.format(zhHans: "链接：%@", en: "Link: %@", entity.url))
            }
            if !entity.snippet.isEmpty {
                lines.append(L10n.format(zhHans: "介绍：%@", en: "Summary: %@", entity.snippet))
            }
            if let reason = entity.whyThis ?? trace.whyThis, !reason.isEmpty {
                lines.append(L10n.format(zhHans: "判定依据：%@", en: "Why this: %@", reason))
            }
            lines.append("")
        }

        if !trace.summary.isEmpty {
            lines.append(L10n.format(zhHans: "结论：%@", en: "Conclusion: %@", trace.summary))
        }

        if let eventSummary = trace.eventSummary, !eventSummary.isEmpty {
            lines.append("")
            lines.append(L10n.format(zhHans: "事件补充：%@", en: "Event notes: %@", eventSummary))
        }

        if !trace.sources.isEmpty {
            lines.append("")
            lines.append(L10n.text(zhHans: "候选来源：", en: "Candidate sources:"))
            lines.append(
                trace.sources.enumerated().map { idx, src in
                    "\(idx + 1). \(src.title)\n\(src.url)\n\(src.snippet)"
                }.joined(separator: "\n\n")
            )
        }

        if lines.isEmpty {
            return trace.summary
        }
        return lines.joined(separator: "\n")
    }

    private static func mergedMetadata(
        base: [String: String],
        context: SkillExecutionContext?
    ) -> [String: String] {
        guard let context else { return base }
        var metadata = base
        metadata["followup_depth"] = String(max(0, context.followupDepth))
        if let followupSourceSkillID = context.followupSourceSkillID,
           !followupSourceSkillID.isEmpty {
            metadata["followup_source_skill_id"] = followupSourceSkillID
        }
        return metadata
    }
}
