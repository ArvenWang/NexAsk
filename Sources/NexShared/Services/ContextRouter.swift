import AppKit
import Foundation

struct SkillIntentScore {
    let skillID: String
    let ruleScore: Double
    let usageScore: Double
    let score: Double
    let reason: String
}

struct SkillRouteResult {
    let contextType: ActivationSource
    let contentCategory: String
    let likelyIntents: [SkillIntentScore]
    let primarySkillIDs: [String]
    let secondarySkillIDs: [String]
    let confidence: Double
}

final class ContextRouter {
    private let actionRegistry: ActionRegistry
    private let usageLearningStore: UsageLearningStore

    init(
        actionRegistry: ActionRegistry = .shared,
        usageLearningStore: UsageLearningStore = .shared
    ) {
        self.actionRegistry = actionRegistry
        self.usageLearningStore = usageLearningStore
    }

    func route(
        context: ActivationContext,
        sourceInteractionContext: SourceInteractionContext = .empty,
        candidates: [SkillDefinition],
        maxPrimarySkillCount: Int = 3
    ) -> SkillRouteResult {
        guard !candidates.isEmpty else {
            return SkillRouteResult(
                contextType: context.source,
                contentCategory: "general_text",
                likelyIntents: [],
                primarySkillIDs: [],
                secondarySkillIDs: [],
                confidence: 0
            )
        }

        if context.source == .fileSelection {
            return routeFileSelection(
                context: context,
                candidates: candidates,
                maxPrimarySkillCount: maxPrimarySkillCount
            )
        }

        if context.contentType == .image {
            return routeImageCapture(
                context: context,
                candidates: candidates,
                maxPrimarySkillCount: maxPrimarySkillCount
            )
        }

        let text = context.text
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            let primary = actionRegistry.defaultPrimarySkillIDs(settings: .shared, maxCount: maxPrimarySkillCount)
            let secondary = actionRegistry.defaultSecondarySkillIDs(settings: .shared, excluding: primary)
            return SkillRouteResult(
                contextType: context.source,
                contentCategory: "general_text",
                likelyIntents: primary.map {
                    SkillIntentScore(
                        skillID: $0,
                        ruleScore: 0.2,
                        usageScore: 0,
                        score: 0.2,
                        reason: L10n.text(zhHans: "空上下文时使用默认技能顺序。", en: "Use the default skill order when the context is empty.")
                    )
                },
                primarySkillIDs: primary,
                secondarySkillIDs: secondary,
                confidence: 0.2
            )
        }

        let analysis = analyze(text: normalized)
        let effectiveCandidates = analysis.isStandaloneURL
            ? candidates
            : (analysis.detectedURL == nil ? candidates.filter { $0.skillID != "collect" } : candidates)
        let usageAdjustments = usageLearningStore.adjustments(
            for: effectiveCandidates.map(\.skillID),
            selectionType: context.contentType.rawValue,
            bundleID: context.metadata.bundleID,
            contentCategory: analysis.category
        )
        let anchors = effectiveCandidates
            .filter { $0.priorityTier == .anchor }
            .sorted(by: sortDefinitions)
        let ranked = effectiveCandidates
            .map { definition in
                score(
                    definition: definition,
                    analysis: analysis,
                    sourceInteractionContext: sourceInteractionContext,
                    usageAdjustment: usageAdjustments[definition.skillID]
                )
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return sortDefinitions($0.definition, $1.definition)
            }

        let eligibleRanked = ranked.filter { $0.score > 0 }

        var primary: [String] = []
        var seen: Set<String> = []
        for definition in anchors {
            primary.append(definition.skillID)
            seen.insert(definition.skillID)
            if primary.count >= maxPrimarySkillCount {
                break
            }
        }

        for item in eligibleRanked where item.score >= 0.18 {
            guard !seen.contains(item.definition.skillID) else { continue }
            primary.append(item.definition.skillID)
            seen.insert(item.definition.skillID)
            if primary.count >= maxPrimarySkillCount {
                break
            }
        }

        if primary.count < maxPrimarySkillCount {
            for item in eligibleRanked {
                guard !seen.contains(item.definition.skillID) else { continue }
                primary.append(item.definition.skillID)
                seen.insert(item.definition.skillID)
                if primary.count >= maxPrimarySkillCount {
                    break
                }
            }
        }

        let secondary = eligibleRanked
            .filter { !seen.contains($0.definition.skillID) }
            .filter { shouldExposeInMoreMenu(skillID: $0.definition.skillID, score: $0.score) }
            .map(\.definition.skillID)

        let likelyIntents = ranked.map {
            SkillIntentScore(
                skillID: $0.definition.skillID,
                ruleScore: $0.ruleScore,
                usageScore: $0.usageScore,
                score: $0.score,
                reason: $0.reason
            )
        }

        return SkillRouteResult(
            contextType: context.source,
            contentCategory: analysis.category,
            likelyIntents: likelyIntents,
            primarySkillIDs: primary,
            secondarySkillIDs: secondary,
            confidence: ranked.first?.score ?? 0.2
        )
    }

    private func routeFileSelection(
        context: ActivationContext,
        candidates: [SkillDefinition],
        maxPrimarySkillCount: Int
    ) -> SkillRouteResult {
        let filePaths = context.raw.filePaths ?? []
        let category = fileCategory(for: filePaths)
        let usageAdjustments = usageLearningStore.adjustments(
            for: candidates.map(\.skillID),
            selectionType: context.contentType.rawValue,
            bundleID: context.metadata.bundleID,
            contentCategory: category
        )

        let ranked = candidates
            .map { definition in
                let baseRule = definition.manifest.routing.priorityRules?[category]
                    ?? definition.manifest.routing.priorityRules?["file_selection"]
                    ?? 0.06
                let contentHints = Set(definition.manifest.routing.contentHints ?? [])
                let requiredCategories = Set(definition.manifest.routing.requiredContentCategories ?? [])
                var ruleScore = baseRule
                if !requiredCategories.isEmpty, !requiredCategories.contains(category) {
                    ruleScore = 0
                }
                if contentHints.contains(category) {
                    ruleScore += 0.08
                }

                let usageScore = max(-0.12, min(0.12, usageAdjustments[definition.skillID]?.scoreDelta ?? 0))
                let score = max(0, min(0.99, ruleScore + usageScore))
                let reason = fileRoutingReason(for: category, definition: definition, usageAdjustment: usageAdjustments[definition.skillID])
                return SkillIntentScore(
                    skillID: definition.skillID,
                    ruleScore: max(0, min(0.99, ruleScore)),
                    usageScore: usageScore,
                    score: score,
                    reason: reason
                )
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                guard let lhs = actionRegistry.definition(forSkillID: $0.skillID),
                      let rhs = actionRegistry.definition(forSkillID: $1.skillID) else {
                    return $0.skillID < $1.skillID
                }
                return sortDefinitions(lhs, rhs)
            }

        let eligibleRanked = ranked.filter { $0.score > 0 }
        let primary = Array(eligibleRanked.prefix(maxPrimarySkillCount).map(\.skillID))
        let seenPrimary = Set(primary)
        let secondary = eligibleRanked
            .filter { !seenPrimary.contains($0.skillID) }
            .filter { shouldExposeInMoreMenu(skillID: $0.skillID, score: $0.score) }
            .map(\.skillID)
        return SkillRouteResult(
            contextType: context.source,
            contentCategory: category,
            likelyIntents: ranked,
            primarySkillIDs: primary,
            secondarySkillIDs: secondary,
            confidence: ranked.first?.score ?? 0.2
        )
    }

    private func routeImageCapture(
        context: ActivationContext,
        candidates: [SkillDefinition],
        maxPrimarySkillCount: Int
    ) -> SkillRouteResult {
        let recognizedText = context.raw.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognizedTextLength = context.raw.recognizedTextLength ?? recognizedText?.count ?? 0
        let ocrLineCount = context.raw.ocrLineCount ?? 0
        let hasMeaningfulText = recognizedTextLength >= 8 || ocrLineCount >= 2

        guard hasMeaningfulText, let recognizedText, !recognizedText.isEmpty else {
            let category = "image_capture"
            let imageCandidates = candidates.filter { definition in
                switch definition.skillID {
                case "screenshot_ocr":
                    return false
                case "screenshot_save":
                    return true
                default:
                    return definition.manifest.routing.priorityRules?[category] != nil
                }
            }
            let effectiveCandidates = imageCandidates.isEmpty ? candidates : imageCandidates
            let usageAdjustments = usageLearningStore.adjustments(
                for: effectiveCandidates.map(\.skillID),
                selectionType: context.contentType.rawValue,
                bundleID: context.metadata.bundleID,
                contentCategory: category
            )

            let ranked = effectiveCandidates
                .map { definition -> SkillIntentScore in
                    let usageScore = max(-0.12, min(0.12, usageAdjustments[definition.skillID]?.scoreDelta ?? 0))
                    let ruleScore: Double
                    let reason: String
                    switch definition.skillID {
                    case "screenshot_save":
                        ruleScore = 0.72
                        reason = L10n.text(zhHans: "当前截图主要按图片能力处理，保存会保留在可用位置。", en: "This screenshot is being treated as a visual capture first, so Save remains available.")
                    default:
                        ruleScore = max(
                            0,
                            min(
                                0.99,
                                (definition.manifest.routing.priorityRules?[category]
                                    ?? definition.manifest.routing.priorityRules?["image_file"]
                                    ?? 0.05) - 0.18
                            )
                        )
                        reason = L10n.text(zhHans: "当前截图更像纯视觉区域，暂不提升基于文字理解的技能。", en: "This screenshot looks more visual than textual, so text-driven skills are not being promoted yet.")
                    }
                    let score = max(0, min(0.99, ruleScore + usageScore))
                    return SkillIntentScore(
                        skillID: definition.skillID,
                        ruleScore: ruleScore,
                        usageScore: usageScore,
                        score: score,
                        reason: reason
                    )
                }
                .sorted {
                    if $0.score != $1.score {
                        return $0.score > $1.score
                    }
                    guard let lhs = actionRegistry.definition(forSkillID: $0.skillID),
                          let rhs = actionRegistry.definition(forSkillID: $1.skillID) else {
                        return $0.skillID < $1.skillID
                    }
                    return sortDefinitions(lhs, rhs)
                }

            let eligibleRanked = ranked.filter { $0.score > 0 }
            let primary = Array(eligibleRanked.prefix(maxPrimarySkillCount).map(\.skillID))
            let seenPrimary = Set(primary)
            let secondary = eligibleRanked
                .filter { !seenPrimary.contains($0.skillID) }
                .filter { shouldExposeInMoreMenu(skillID: $0.skillID, score: $0.score) }
                .map(\.skillID)
            return SkillRouteResult(
                contextType: context.source,
                contentCategory: category,
                likelyIntents: ranked,
                primarySkillIDs: primary,
                secondarySkillIDs: secondary,
                confidence: ranked.first?.score ?? 0.2
            )
        }

        let analysis = analyze(text: recognizedText)
        let category = analysis.category
        let usageAdjustments = usageLearningStore.adjustments(
            for: candidates.map(\.skillID),
            selectionType: context.contentType.rawValue,
            bundleID: context.metadata.bundleID,
            contentCategory: category
        )

        let effectiveCandidates = analysis.isStandaloneURL
            ? candidates
            : (analysis.detectedURL == nil ? candidates.filter { $0.skillID != "collect" } : candidates)
        let ranked = effectiveCandidates
            .map { definition -> SkillIntentScore in
                let base = score(
                    definition: definition,
                    analysis: analysis,
                    sourceInteractionContext: .empty,
                    usageAdjustment: usageAdjustments[definition.skillID]
                )
                let usageScore = base.usageScore
                let ruleScore: Double
                let reason: String
                switch definition.skillID {
                case "screenshot_ocr":
                    ruleScore = max(base.ruleScore, 0.84)
                    reason = L10n.text(zhHans: "截图中识别到了可用文字，OCR 与基于文字的技能都会更有用。", en: "Usable text was recognized in the screenshot, so OCR and text-aware skills both become more useful.")
                case "screenshot_save":
                    ruleScore = 0.24
                    reason = L10n.text(zhHans: "截图里已有足够文字可用于理解，保存仍保留在次级位置。", en: "There is enough text in the screenshot to drive semantic skills, so Save stays available as a secondary option.")
                default:
                    ruleScore = base.ruleScore
                    reason = base.reason
                }
                let score = max(0, min(0.99, ruleScore + usageScore))
                return SkillIntentScore(
                    skillID: definition.skillID,
                    ruleScore: ruleScore,
                    usageScore: usageScore,
                    score: score,
                    reason: reason
                )
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                guard let lhs = actionRegistry.definition(forSkillID: $0.skillID),
                      let rhs = actionRegistry.definition(forSkillID: $1.skillID) else {
                    return $0.skillID < $1.skillID
                }
                return sortDefinitions(lhs, rhs)
            }

        let eligibleRanked = ranked.filter { $0.score > 0 }

        var primary: [String] = []
        var seen: Set<String> = []
        if effectiveCandidates.contains(where: { $0.skillID == "screenshot_ocr" }),
           let ocrIntent = eligibleRanked.first(where: { $0.skillID == "screenshot_ocr" }) {
            primary.append(ocrIntent.skillID)
            seen.insert(ocrIntent.skillID)
        }

        for item in eligibleRanked where item.score >= 0.18 {
            guard !seen.contains(item.skillID) else { continue }
            primary.append(item.skillID)
            seen.insert(item.skillID)
            if primary.count >= maxPrimarySkillCount {
                break
            }
        }

        if primary.count < maxPrimarySkillCount {
            for item in eligibleRanked {
                guard !seen.contains(item.skillID) else { continue }
                primary.append(item.skillID)
                seen.insert(item.skillID)
                if primary.count >= maxPrimarySkillCount {
                    break
                }
            }
        }

        let secondary = eligibleRanked
            .filter { !seen.contains($0.skillID) }
            .filter { shouldExposeInMoreMenu(skillID: $0.skillID, score: $0.score) }
            .map(\.skillID)
        return SkillRouteResult(
            contextType: context.source,
            contentCategory: category,
            likelyIntents: ranked,
            primarySkillIDs: primary,
            secondarySkillIDs: secondary,
            confidence: ranked.first?.score ?? 0.2
        )
    }

    private func fileCategory(for filePaths: [String]) -> String {
        guard !filePaths.isEmpty else { return "file_selection" }
        if filePaths.allSatisfy(\.isSupportedImageFilePath) {
            return "image_file"
        }
        return "file_selection"
    }

    private func fileRoutingReason(
        for category: String,
        definition: SkillDefinition,
        usageAdjustment: UsageLearningAdjustment?
    ) -> String {
        let baseReason: String
        switch category {
        case "image_file":
            if definition.skillID == "compress" {
                baseReason = L10n.text(zhHans: "当前选中的是可压缩文件，优先推荐压缩。", en: "The current selection contains compressible files, so compression is recommended first.")
            } else {
                baseReason = L10n.text(zhHans: "当前选中的是图片文件，按文件技能优先级排序。", en: "The current selection contains image files, so file-skill priority is used.")
            }
        default:
            baseReason = L10n.text(zhHans: "检测到文件选择，按文件类技能排序。", en: "File selection detected, so NexHub ranked file-related skills first.")
        }

        guard let usageReason = usageAdjustment?.reason, !usageReason.isEmpty else {
            return baseReason
        }
        let trimmedBase = baseReason.hasSuffix("。") ? String(baseReason.dropLast()) : baseReason
        return "\(trimmedBase)；\(usageReason)。"
    }

    private func sortDefinitions(_ lhs: SkillDefinition, _ rhs: SkillDefinition) -> Bool {
        if lhs.priorityTier != rhs.priorityTier {
            return priorityWeight(lhs.priorityTier) < priorityWeight(rhs.priorityTier)
        }
        if lhs.fallbackRank != rhs.fallbackRank {
            return lhs.fallbackRank < rhs.fallbackRank
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func priorityWeight(_ tier: SkillPriorityTier) -> Int {
        switch tier {
        case .anchor: return 0
        case .recommended: return 1
        case .secondary: return 2
        case .hidden: return 3
        }
    }

    private func score(
        definition: SkillDefinition,
        analysis: TextAnalysis,
        sourceInteractionContext: SourceInteractionContext,
        usageAdjustment: UsageLearningAdjustment?
    ) -> (definition: SkillDefinition, ruleScore: Double, usageScore: Double, score: Double, reason: String) {
        let routing = definition.manifest.routing
        var ruleScore = routing.priorityRules?[analysis.category] ?? 0.08
        let contentHints = Set(routing.contentHints ?? [])
        let intentHints = Set(routing.intentHints)
        let requiredCategories = Set(routing.requiredContentCategories ?? [])
        let satisfiesRequiredCategory = requiredCategories.isEmpty || requiredCategories.contains(analysis.category)
        let satisfiesWritebackRequirement = routing.requiresMessageWriteback != true || sourceInteractionContext.deliveryTarget.supportsWriteback
        let satisfiesReplaceRequirement = routing.requiresReplaceSelection != true || sourceInteractionContext.supportsReplaceSelection

        if satisfiesRequiredCategory && satisfiesWritebackRequirement && satisfiesReplaceRequirement {
            if contentHints.contains(analysis.category) {
                ruleScore += 0.06
            }

            if sourceInteractionContext.deliveryTarget.supportsWriteback {
                ruleScore += routing.messageWritebackBonus ?? 0
            }

            if sourceInteractionContext.supportsReplaceSelection {
                ruleScore += routing.replaceSelectionBonus ?? 0
            }

            if intentHints.contains(analysis.primaryIntentHint) {
                ruleScore += 0.05
            }
        } else {
            ruleScore = 0
        }

        if let minLength = definition.manifest.input.minLength, analysis.length < minLength {
            ruleScore = 0
        }
        if let maxLength = definition.manifest.input.maxLength, analysis.length > maxLength {
            ruleScore *= 0.5
        }

        let usageReason = usageAdjustment?.reason
        ruleScore = max(0, min(0.99, ruleScore))
        let clampedUsageScore = max(-0.12, min(0.12, usageAdjustment?.scoreDelta ?? 0))
        let score = max(0, min(0.99, ruleScore + clampedUsageScore))
        let baseReason = analysis.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentReason = routingEnvironmentReason(
            for: definition.skillID,
            analysis: analysis,
            sourceInteractionContext: sourceInteractionContext
        )
        let reason: String
        if let usageReason, !usageReason.isEmpty, !environmentReason.isEmpty {
            let trimmedBase = baseReason.hasSuffix("。") ? String(baseReason.dropLast()) : baseReason
            reason = "\(trimmedBase)；\(environmentReason)；\(usageReason)。"
        } else if let usageReason, !usageReason.isEmpty {
            let trimmedBase = baseReason.hasSuffix("。") ? String(baseReason.dropLast()) : baseReason
            reason = "\(trimmedBase)；\(usageReason)。"
        } else if !environmentReason.isEmpty {
            let trimmedBase = baseReason.hasSuffix("。") ? String(baseReason.dropLast()) : baseReason
            reason = "\(trimmedBase)；\(environmentReason)。"
        } else {
            reason = baseReason
        }
        return (definition, ruleScore, clampedUsageScore, score, reason)
    }

    private func routingEnvironmentReason(
        for skillID: String,
        analysis: TextAnalysis,
        sourceInteractionContext: SourceInteractionContext
    ) -> String {
        switch skillID {
        case "reply":
            if sourceInteractionContext.deliveryTarget.supportsWriteback,
               (analysis.looksChatMessage || analysis.looksFeedbackRequest) {
                return L10n.text(zhHans: "当前在可写回的聊天输入环境里，回复结果更容易直接交付", en: "A writable chat composer is available, so a reply can be delivered directly")
            }
            if !sourceInteractionContext.deliveryTarget.supportsWriteback {
                return L10n.text(zhHans: "当前不是可直接写回的聊天交付环境，回复优先级会更克制", en: "This is not a direct writeback chat environment, so reply is ranked more conservatively")
            }
        case "translate":
            if sourceInteractionContext.supportsReplaceSelection,
               (analysis.isForeignText || analysis.isMixedLanguage) {
                return L10n.text(zhHans: "当前抓到了可替换输入目标，翻译结果更容易直接落回原输入区", en: "A replaceable input target was captured, so translation can flow back into the original input more easily")
            }
        default:
            break
        }

        return ""
    }
    private func shouldExposeInMoreMenu(skillID: String, score: Double) -> Bool {
        guard let definition = actionRegistry.definition(forSkillID: skillID) else {
            return false
        }
        guard definition.priorityTier != .hidden else { return false }

        let threshold: Double
        switch definition.priorityTier {
        case .anchor, .recommended:
            threshold = 0.05
        case .secondary:
            threshold = 0.08
        case .hidden:
            threshold = 1
        }

        return score >= threshold
    }

    private func analyze(text: String) -> TextAnalysis {
        let length = text.count
        let lower = text.lowercased()
        let latinCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
        let chineseCount = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
        let isShort = length <= 36
        let isForeignText = latinCount > 0 && (chineseCount == 0 || Double(latinCount) / Double(max(1, latinCount + chineseCount)) > 0.58)
        let isMixedLanguage = latinCount > 0 && chineseCount > 0

        let chatTerms = ["谢谢", "麻烦", "方便", "抱歉", "辛苦", "收到", "能不能", "可以吗", "在吗", "好的", "嗯", "哈喽", "hi", "hello"]
        let feedbackTerms = ["帮我", "麻烦你", "可否", "尽快", "反馈", "确认一下", "同步", "跟进", "谢谢你", "辛苦了"]
        let docsTerms = ["文档", "docs", "api", "sdk", "guide", "教程", "接入", "参数", "reference"]
        let announceTerms = ["官宣", "发布", "更新", "版本", "changelog", "announcement", "blog", "release notes"]
        let productTerms = ["模型", "model", "agent", "cursor", "claude", "openai", "meta", "feature", "功能", "产品", "平台", "repo", "github"]
        let technicalTerms = ["架构", "runtime", "manifest", "schema", "ndjson", "接口", "布局", "动画", "编译", "部署", "api", "sdk", "router"]
        let timeTerms = ["提醒", "日程", "预约", "会议", "开会", "截止", "deadline", "约", "打卡", "签到", "面试", "出发", "航班", "火车", "高铁"]
        let timePatterns = ["点", "号", "月", "周一", "周二", "周三", "周四", "周五", "周六", "周日", "下午", "上午", "晚上", "早上", "明天", "后天", "今天", "今晚", "明早"]

        let conversationalMarkers = [
            "你", "你那边", "你这边", "请你", "麻烦你", "辛苦你", "方便的话",
            "回我", "回一下", "回复我", "收到请回", "帮我", "帮忙"
        ]
        let hasQuestion = text.contains("？") || text.contains("?")
        let hasConversationalMarker = conversationalMarkers.contains(where: { text.contains($0) || lower.contains($0) })
        let looksChatMessage = chatTerms.contains(where: { lower.contains($0) })
            || (length <= 160 && hasQuestion && hasConversationalMarker)
            || (length <= 80 && hasConversationalMarker)
        let looksFeedbackRequest = feedbackTerms.contains(where: { lower.contains($0) })
        let looksDocumentation = docsTerms.contains(where: { lower.contains($0) })
        let looksAnnouncement = announceTerms.contains(where: { lower.contains($0) })
        let looksProductOrModel = productTerms.contains(where: { lower.contains($0) }) || text.contains("://")
        let looksTechnical = technicalTerms.contains(where: { lower.contains($0) }) || length >= 140
        let referenceTerms = ["faq", "meeting notes", "纪要", "总结", "spec", "prd", "设计稿", "说明书", "教程", "guide"]
        let looksReferenceText = referenceTerms.contains(where: { lower.contains($0) }) || length >= 280
        let collectTerms = ["采集", "入库", "归档", "存档", "保存到知识库", "archive", "collect", "save to knowledge base", "knowledge base"]
        let looksCollectIntent = collectTerms.contains(where: { lower.contains($0) })
        let detectedURL = TextURLDetector.detect(in: text)
        let isStandaloneURL = detectedURL?.isStandalone == true
        let looksTimeRelated: Bool = {
            let hasTimeTerm = timeTerms.contains(where: { lower.contains($0) })
            let hasTimePattern = timePatterns.contains(where: { lower.contains($0) })
            // Need at least one time term AND one time pattern, or strong time signals
            if hasTimeTerm && hasTimePattern { return true }
            // Check for digit + time unit patterns like "3点" "15号" "10月"
            let digitTimePattern = try? NSRegularExpression(pattern: "\\d+\\s*[点号月日时分]|\\d{1,2}\\s*[:：]\\s*\\d{2}")
            let hasDigitTime = (digitTimePattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) != nil
            if hasTimeTerm && hasDigitTime { return true }
            if hasDigitTime && hasTimePattern { return true }
            // Strong standalone signals
            let strongSignals = ["提醒我", "别忘了", "记得", "不要忘", "定个", "约个"]
            let hasStrongSignal = strongSignals.contains(where: { lower.contains($0) })
            if hasStrongSignal && (hasTimePattern || hasDigitTime || hasTimeTerm) { return true }
            return false
        }()

        let category: String
        let primaryIntentHint: String
        let reason: String

        if let detectedURL {
            category = detectedURL.isStandalone ? "standalone_url" : "embedded_url"
            primaryIntentHint = "collect"
            reason = detectedURL.isStandalone
                ? L10n.text(zhHans: "检测到独立链接文本，优先推荐采集到知识库。", en: "A standalone URL was detected, so collecting it into the knowledge base is recommended first.")
                : L10n.text(zhHans: "检测到文本中包含链接，采集时会优先抓取该链接。", en: "A link was detected inside the selected text, so collect will capture that link first.")
        } else if looksTimeRelated {
            category = "time_reference"
            primaryIntentHint = "schedule"
            reason = L10n.text(zhHans: "文本包含时间相关的意图，优先推荐创建日程提醒。", en: "The text contains time-related intent, so creating a schedule reminder is recommended first.")
        } else if looksChatMessage {
            category = looksFeedbackRequest ? "feedback_request" : "chat_message"
            primaryIntentHint = "reply"
            reason = L10n.text(zhHans: "文本更像沟通语句，优先推荐可直接发送的回复。", en: "The text looks more like a conversation, so a sendable reply is recommended first.")
        } else if isForeignText {
            category = isShort ? "foreign_text" : "long_foreign_text"
            primaryIntentHint = "translation"
            reason = L10n.text(zhHans: "文本以外语为主，优先推荐翻译。", en: "The text is primarily in a foreign language, so translation is recommended first.")
        } else if isMixedLanguage {
            category = "mixed_language"
            primaryIntentHint = "translation"
            reason = L10n.text(zhHans: "文本中英文混合，翻译和解释都可能有用。", en: "The text mixes Chinese and English, so both translation and explanation may help.")
        } else if looksDocumentation {
            category = "documentation_query"
            primaryIntentHint = "documentation"
            reason = L10n.text(zhHans: "文本像在找文档、参数或接入方式。", en: "The text looks like a query for docs, parameters, or integration details.")
        } else if looksAnnouncement {
            category = "news_or_announcement"
            primaryIntentHint = "official_source"
            reason = L10n.text(zhHans: "文本像在确认发布、更新或官宣出处。", en: "The text looks like it is checking a release, update, or official announcement source.")
        } else if looksProductOrModel {
            category = "product_or_model_mention"
            primaryIntentHint = "product_lookup"
            reason = L10n.text(zhHans: "文本提到产品、模型或入口，适合做实体理解与源头定位。", en: "The text mentions a product, model, or entry point, which is a good fit for entity understanding and source resolution.")
        } else if looksTechnical {
            category = "technical_paragraph"
            primaryIntentHint = "explanation"
            reason = L10n.text(zhHans: "文本较长且偏技术，优先推荐解释。", en: "The text is relatively long and technical, so explanation is recommended first.")
        } else {
            category = isShort ? "unclear_term" : "general_text"
            primaryIntentHint = "explanation"
            reason = isShort
                ? L10n.text(zhHans: "短文本更像一个待解释的词或短语。", en: "The short text looks more like a term or phrase to explain.")
                : L10n.text(zhHans: "未命中特定模式，采用通用理解路径。", en: "No specific pattern was matched, so NexHub is using the general understanding path.")
        }

        return TextAnalysis(
            length: length,
            category: category,
            primaryIntentHint: primaryIntentHint,
            reason: reason,
            isShort: isShort,
            isForeignText: isForeignText,
            isMixedLanguage: isMixedLanguage,
            detectedURL: detectedURL?.url,
            isStandaloneURL: isStandaloneURL,
            looksChatMessage: looksChatMessage,
            looksFeedbackRequest: looksFeedbackRequest,
            looksDocumentation: looksDocumentation,
            looksAnnouncement: looksAnnouncement,
            looksProductOrModel: looksProductOrModel,
            looksTechnical: looksTechnical,
            looksReferenceText: looksReferenceText,
            looksTimeRelated: looksTimeRelated,
            looksCollectIntent: looksCollectIntent
        )
    }

}

private struct TextAnalysis {
    let length: Int
    let category: String
    let primaryIntentHint: String
    let reason: String
    let isShort: Bool
    let isForeignText: Bool
    let isMixedLanguage: Bool
    let detectedURL: URL?
    let isStandaloneURL: Bool
    let looksChatMessage: Bool
    let looksFeedbackRequest: Bool
    let looksDocumentation: Bool
    let looksAnnouncement: Bool
    let looksProductOrModel: Bool
    let looksTechnical: Bool
    let looksReferenceText: Bool
    let looksTimeRelated: Bool
    let looksCollectIntent: Bool
}

private extension String {
    var isSupportedImageFilePath: Bool {
        let ext = URL(fileURLWithPath: self).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff", "bmp"].contains(ext)
    }
}
