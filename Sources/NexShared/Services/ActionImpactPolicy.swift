import Foundation

enum ActionImpactLevel: String {
    case passive
    case mutating
    case highImpact = "high_impact"
}

enum ResultActionSemantic: String {
    case regenerate
    case copy
    case translateShortcut = "translate_shortcut"
    case explainShortcut = "explain_shortcut"
    case followup = "followup"
    case replaceSelection = "replace_selection"
    case writeInput = "write_input"
    case openPrimary = "open_primary"
    case openURL = "open_url"
    case openFile = "open_file"
    case revealInFinder = "reveal_in_finder"
    case showCapturedText = "show_captured_text"
    case createCalendarEvent = "create_calendar_event"
    case createReminder = "create_reminder"
}

enum ResultActionDisposition: String {
    case executeImmediately = "execute_immediately"
    case openCalendarDraft = "open_calendar_draft"
}

struct ResultActionPolicyDecision {
    let semantic: ResultActionSemantic
    let impactLevel: ActionImpactLevel
    let disposition: ResultActionDisposition
    let reason: String

    func diagnosticsPayload(skillID: String?, sourceBundleID: String?) -> String {
        [
            "semantic=\(semantic.rawValue)",
            "impact=\(impactLevel.rawValue)",
            "disposition=\(disposition.rawValue)",
            "skill=\(skillID ?? "nil")",
            "bundle=\(sourceBundleID ?? "nil")",
            "reason=\(reason)"
        ].joined(separator: " ")
    }
}

enum ActionImpactPolicy {
    static func impactLevel(for definition: SkillDefinition) -> ActionImpactLevel {
        if definition.supportsWriteback
            || definition.skillID == "schedule"
            || definition.requiredEntitlementTier != nil
            || definition.billingClass == .usageMetered {
            return .highImpact
        }

        if definition.supportsReplace {
            return .mutating
        }

        return .passive
    }

    static func decision(
        forFooterAction semantic: ResultActionSemantic,
        definition: SkillDefinition?,
        supportsWritebackToSource: Bool
    ) -> ResultActionPolicyDecision {
        switch semantic {
        case .replaceSelection:
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .mutating,
                disposition: .executeImmediately,
                reason: "explicit_replace_requested"
            )
        case .writeInput:
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .highImpact,
                disposition: .executeImmediately,
                reason: supportsWritebackToSource
                    ? "explicit_cross_app_writeback_requested"
                    : "explicit_writeback_requested_with_fallback"
            )
        case .regenerate:
            let reason: String
            if let definition {
                reason = "rerun_\(impactLevel(for: definition).rawValue)_skill"
            } else {
                reason = "rerun_current_skill"
            }
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: definition.map(impactLevel(for:)) ?? .passive,
                disposition: .executeImmediately,
                reason: reason
            )
        case .copy, .translateShortcut, .explainShortcut, .followup, .openPrimary, .openURL, .openFile, .revealInFinder, .showCapturedText:
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .passive,
                disposition: .executeImmediately,
                reason: semantic == .followup ? "explicit_followup_requested" : "explicit_non_mutating_action"
            )
        case .createCalendarEvent, .createReminder:
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .highImpact,
                disposition: .executeImmediately,
                reason: "calendar_action_without_intent_context"
            )
        }
    }

    static func decision(
        forCardAction action: SkillResultAction,
        calendarIntent: CalendarEventIntent?
    ) -> ResultActionPolicyDecision {
        let semantic: ResultActionSemantic
        switch action.type {
        case .openURL:
            semantic = .openURL
        case .openFile:
            semantic = .openFile
        case .revealInFinder:
            semantic = .revealInFinder
        case .showCapturedText:
            semantic = .showCapturedText
        case .copyText:
            semantic = .copy
        case .replaceSelection:
            semantic = .replaceSelection
        case .createCalendarEvent:
            semantic = .createCalendarEvent
        case .createReminder:
            semantic = .createReminder
        case .none:
            semantic = .openPrimary
        }

        switch action.type {
        case .createCalendarEvent, .createReminder:
            if calendarIntent?.needsConfirmation == true {
                return ResultActionPolicyDecision(
                    semantic: semantic,
                    impactLevel: .highImpact,
                    disposition: .openCalendarDraft,
                    reason: "calendar_intent_requires_confirmation"
                )
            }

            if calendarIntent?.resolvedStartDate == nil {
                return ResultActionPolicyDecision(
                    semantic: semantic,
                    impactLevel: .highImpact,
                    disposition: .openCalendarDraft,
                    reason: "calendar_intent_missing_resolved_start"
                )
            }

            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .highImpact,
                disposition: .executeImmediately,
                reason: "calendar_intent_ready_for_creation"
            )
        case .replaceSelection:
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .mutating,
                disposition: .executeImmediately,
                reason: "explicit_replace_requested"
            )
        case .openURL, .openFile, .revealInFinder, .showCapturedText, .copyText, .none:
            return ResultActionPolicyDecision(
                semantic: semantic,
                impactLevel: .passive,
                disposition: .executeImmediately,
                reason: "explicit_non_mutating_action"
            )
        }
    }
}
