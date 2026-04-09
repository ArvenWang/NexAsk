import Foundation

package enum AppProductProfile: String {
    case unified
    case nexhub
    case nexask

    private static let infoDictionaryKey = "NexHubProductProfile"

    package enum StatusItemPrimaryAction {
        case conversation
        case menu
    }

    package static var current: AppProductProfile {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String else {
            return .unified
        }
        return AppProductProfile(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unified
    }

    package var statusItemPrimaryAction: StatusItemPrimaryAction {
        switch self {
        case .unified, .nexask:
            return .conversation
        case .nexhub:
            return .menu
        }
    }

    package var settingsGeneralSubtitleText: String {
        switch self {
        case .unified:
            return L10n.text(
                zhHans: "控制划词、文件选择、截图和画框对话四条 AI 入口，以及兼容应用和截图默认保存位置。",
                en: "Control the four AI entry paths: text selection, file selection, screenshot, and the conversation box, plus compatible apps and the default screenshot save location."
            )
        case .nexhub:
            return L10n.format(
                zhHans: "控制 %@ 的划词、文件选择和截图三条入口，以及兼容应用和截图默认保存位置。",
                en: "Control %@'s three entry paths: text selection, file selection, and screenshot, plus compatible apps and the default screenshot save location.",
                AppBrand.displayName
            )
        case .nexask:
            return L10n.format(
                zhHans: "控制 %@ 的语言和基础运行选项。",
                en: "Control %@ language and core runtime options.",
                AppBrand.displayName
            )
        }
    }

    package var settingsShortcutTipText: String {
        switch self {
        case .unified:
            return L10n.text(
                zhHans: "说明：\n1) 选中文本后会自动出现 AI 浮条\n2) 按住 Alt 拖拽可在任意位置开启画框对话\n3) 按截图快捷键进入框选截图模式\n4) Esc 会优先取消画框，再关闭对话窗、浮条和结果窗",
                en: "Notes:\n1) The AI toolbar appears automatically when text is selected\n2) Hold Alt and drag anywhere to start a conversation box session\n3) Press the screenshot shortcut to enter region capture mode\n4) Esc cancels the box first, then closes the conversation window, toolbar, and result panel"
            )
        case .nexhub:
            return L10n.text(
                zhHans: "说明：\n1) 选中文本后会自动出现 AI 浮条\n2) 在 Finder 里选中文件也会触发文件入口\n3) 按截图快捷键进入框选截图模式\n4) Esc 会优先取消截图框，再关闭浮条和结果窗",
                en: "Notes:\n1) The AI toolbar appears automatically when text is selected\n2) Selecting files in Finder also triggers the file entry flow\n3) Press the screenshot shortcut to enter region capture mode\n4) Esc cancels the screenshot box first, then closes the toolbar and result panel"
            )
        case .nexask:
            return L10n.text(
                zhHans: "说明：\n1) 当前产品不提供截图快捷键\n2) 如需进入对话，请使用状态栏入口或产品内的主入口",
                en: "Notes:\n1) This product does not expose a screenshot shortcut\n2) Use the menu bar entry or the in-product primary entry to start a conversation"
            )
        }
    }

    package var supportsConversationExperience: Bool {
        self != .nexhub
    }

    package var supportsConversationMenuBarEntry: Bool {
        self != .nexhub
    }

    package var supportsConversationBoxEntry: Bool {
        self != .nexhub
    }

    package var supportsConversationPresence: Bool {
        self != .nexhub
    }

    package var supportsAutomationFeatures: Bool {
        self != .nexhub
    }

    package var supportsTextSelectionEntry: Bool {
        self != .nexask
    }

    package var supportsFileSelectionEntry: Bool {
        self != .nexask
    }

    package var supportsScreenshotEntry: Bool {
        self != .nexask
    }

    package var supportsGlobalInputEventMonitoring: Bool {
        supportsTextSelectionEntry || supportsFileSelectionEntry
    }

    package var supportsQuickActionExperience: Bool {
        supportsGlobalInputEventMonitoring || supportsScreenshotEntry
    }

    package var supportsSkillLibrary: Bool {
        self != .nexask
    }

    package var supportsAutomationTab: Bool {
        self != .nexhub
    }

    package var supportsShortcutsTab: Bool {
        self != .nexask
    }

    package var supportsLearningTab: Bool {
        self != .nexask
    }

    package var requiresAccessibilityPermission: Bool {
        supportsTextSelectionEntry || supportsFileSelectionEntry || supportsConversationExperience
    }

    package var requiresCalendarPermission: Bool {
        supportsAutomationFeatures
    }

    package var requiresAutomationPermission: Bool {
        supportsAutomationFeatures
    }

    package var requiresInputMonitoringPermission: Bool {
        supportsScreenshotEntry || supportsConversationBoxEntry
    }

    package var requiresScreenRecordingPermission: Bool {
        supportsScreenshotEntry
    }

    package var requiresFilesAndFoldersPermission: Bool {
        supportsFileSelectionEntry || supportsConversationExperience
    }

    package var requiresFullDiskAccessPermission: Bool {
        supportsFileSelectionEntry || supportsConversationExperience
    }
}
