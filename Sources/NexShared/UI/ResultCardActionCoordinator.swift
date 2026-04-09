import AppKit

package struct ResultCardActionContext {
    package let currentSkillID: String?
    package let currentSourceBundleID: String?

    package init(currentSkillID: String?, currentSourceBundleID: String?) {
        self.currentSkillID = currentSkillID
        self.currentSourceBundleID = currentSourceBundleID
    }
}

package final class ResultCardActionCoordinator {
    private let diagnosticsLogger: DiagnosticsLogger
    private let contextProvider: () -> ResultCardActionContext
    private let hideHandler: (Bool) -> Void

    package init(
        diagnosticsLogger: DiagnosticsLogger = .shared,
        contextProvider: @escaping () -> ResultCardActionContext,
        hideHandler: @escaping (Bool) -> Void
    ) {
        self.diagnosticsLogger = diagnosticsLogger
        self.contextProvider = contextProvider
        self.hideHandler = hideHandler
    }

    package func performAction(for card: SkillResultCard) {
        guard let action = card.action else { return }
        let context = contextProvider()

        switch action.type {
        case .createCalendarEvent, .createReminder:
            guard let value = action.value,
                  let data = value.data(using: .utf8),
                  let intent = try? JSONDecoder().decode(CalendarEventIntent.self, from: data) else {
                diagnosticsLogger.log("action.card", "failed to decode calendar intent from card \(card.id)")
                return
            }
            let decision = ActionImpactPolicy.decision(forCardAction: action, calendarIntent: intent)
            diagnosticsLogger.log(
                "result.action_policy",
                decision.diagnosticsPayload(skillID: context.currentSkillID, sourceBundleID: context.currentSourceBundleID)
            )
            diagnosticsLogger.log("action.card", "creating calendar event: \(intent.title)")
            hideHandler(true)
            if decision.disposition == .openCalendarDraft {
                CalendarService.openCalendarDraft(for: intent)
                return
            }
            CalendarService.createEvent(from: intent, revealInCalendar: true) { [weak self] success in
                self?.diagnosticsLogger.log("action.card", "calendar event created=\(success)")
                if !success {
                    CalendarService.openCalendarDraft(for: intent)
                }
            }
        case .openURL:
            if shouldHideAfterCardOpen(card: card, context: context) {
                hideHandler(true)
            }
            let decision = ActionImpactPolicy.decision(forCardAction: action, calendarIntent: nil)
            diagnosticsLogger.log(
                "result.action_policy",
                decision.diagnosticsPayload(skillID: context.currentSkillID, sourceBundleID: context.currentSourceBundleID)
            )
            if let value = action.value {
                openTarget(value, cardID: card.id)
            }
        case .openFile:
            if shouldHideAfterCardOpen(card: card, context: context) {
                hideHandler(true)
            }
            let decision = ActionImpactPolicy.decision(forCardAction: action, calendarIntent: nil)
            diagnosticsLogger.log(
                "result.action_policy",
                decision.diagnosticsPayload(skillID: context.currentSkillID, sourceBundleID: context.currentSourceBundleID)
            )
            if let value = action.value {
                let fileURL = URL(fileURLWithPath: value)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    NSWorkspace.shared.open(fileURL)
                }
            }
        case .revealInFinder:
            if shouldHideAfterCardOpen(card: card, context: context) {
                hideHandler(true)
            }
            let decision = ActionImpactPolicy.decision(forCardAction: action, calendarIntent: nil)
            diagnosticsLogger.log(
                "result.action_policy",
                decision.diagnosticsPayload(skillID: context.currentSkillID, sourceBundleID: context.currentSourceBundleID)
            )
            if let value = action.value {
                let fileURL = URL(fileURLWithPath: value)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        case .showCapturedText:
            let decision = ActionImpactPolicy.decision(forCardAction: action, calendarIntent: nil)
            diagnosticsLogger.log(
                "result.action_policy",
                decision.diagnosticsPayload(skillID: context.currentSkillID, sourceBundleID: context.currentSourceBundleID)
            )
            if let value = action.value {
                Task { @MainActor in
                    KnowledgeBaseSourceActionResolver.perform(
                        action: KnowledgeBaseSourceAction(
                            kind: .showCapturedText,
                            label: action.label,
                            value: value
                        ),
                        title: card.title
                    )
                }
            }
        case .copyText:
            let decision = ActionImpactPolicy.decision(forCardAction: action, calendarIntent: nil)
            diagnosticsLogger.log(
                "result.action_policy",
                decision.diagnosticsPayload(skillID: context.currentSkillID, sourceBundleID: context.currentSourceBundleID)
            )
            if let value = action.value {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        default:
            diagnosticsLogger.log("action.card", "unhandled action type: \(action.type) for card \(card.id)")
        }
    }

    private func openTarget(_ value: String, cardID: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalizedTarget: String
        if trimmed.hasPrefix("//") {
            normalizedTarget = "https:" + trimmed
        } else if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil,
                  trimmed.contains("."),
                  !trimmed.contains(" ") {
            normalizedTarget = "https://" + trimmed
        } else {
            normalizedTarget = trimmed
        }

        if let url = URL(string: normalizedTarget) {
            if url.isFileURL {
                let path = url.path
                if FileManager.default.fileExists(atPath: path) {
                    diagnosticsLogger.log("action.card", "open file url card=\(cardID) path=\(path)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return
                }
            }

            diagnosticsLogger.log("action.card", "open url card=\(cardID) value=\(normalizedTarget)")
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            diagnosticsLogger.log("action.card", "open raw file path card=\(cardID) path=\(fileURL.path)")
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        diagnosticsLogger.log("action.card", "failed to open target card=\(cardID) value=\(trimmed)")
    }

    private func shouldHideAfterCardOpen(card: SkillResultCard, context: ResultCardActionContext) -> Bool {
        context.currentSkillID == "compress" && card.kind == "output_directory"
    }
}
