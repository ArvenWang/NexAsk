import Foundation

package enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    package var languageCode: String {
        switch self {
        case .simplifiedChinese:
            return "zh"
        case .english:
            return "en"
        }
    }

    package var settingsDisplayName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    package var localeIdentifier: String {
        switch self {
        case .simplifiedChinese:
            return "zh_CN"
        case .english:
            return "en_US"
        }
    }

    package static func from(languageCode: String) -> AppLanguage {
        let normalized = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("en") {
            return .english
        }
        return .simplifiedChinese
    }
}

package enum L10n {
    private static func automaticKey(zhHans: String, en: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let payload = "\(zhHans)\u{0000}\(en)"
        for byte in payload.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return "auto." + String(format: "%016llx", hash)
    }

    private static func defaultText(language: AppLanguage, zhHans: String, en: String) -> String {
        switch language {
        case .simplifiedChinese:
            return zhHans
        case .english:
            return en
        }
    }

    package static func text(zhHans: String, en: String) -> String {
        text(language: AppSettings.shared.appLanguage, zhHans: zhHans, en: en)
    }

    package static func text(language: AppLanguage, zhHans: String, en: String) -> String {
        let key = automaticKey(zhHans: zhHans, en: en)
        if let localized = LocalizationCatalogStore.string(for: key, language: language) {
            return localized
        }
        return defaultText(language: language, zhHans: zhHans, en: en)
    }

    package static func text(languageCode: String, zhHans: String, en: String) -> String {
        text(language: AppLanguage.from(languageCode: languageCode), zhHans: zhHans, en: en)
    }

    package static func text(key: String, zhHans: String, en: String) -> String {
        let language = AppSettings.shared.appLanguage
        if let localized = LocalizationCatalogStore.string(for: key, language: language) {
            return localized
        }
        return text(language: language, zhHans: zhHans, en: en)
    }

    package static func format(zhHans: String, en: String, _ arguments: CVarArg...) -> String {
        String(format: text(zhHans: zhHans, en: en), locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }

    package static func format(languageCode: String, zhHans: String, en: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(languageCode: languageCode, zhHans: zhHans, en: en),
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: arguments
        )
    }

    package static func format(key: String, zhHans: String, en: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(key: key, zhHans: zhHans, en: en),
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: arguments
        )
    }

    package static var listSeparator: String {
        text(zhHans: "、", en: ", ")
    }

    package static func joinedList(_ items: [String]) -> String {
        items.joined(separator: listSeparator)
    }
}

extension String {
    var containsChineseCharacter: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }
}

extension L10n {
    enum Settings {
        enum Tabs {
            static var general: String { L10n.text(zhHans: "通用", en: "General") }
            static var skills: String { L10n.text(zhHans: "技能", en: "Skills") }
            static var knowledgeBase: String { L10n.text(zhHans: "知识库", en: "Knowledge Base") }
            static var privacy: String { L10n.text(zhHans: "隐私", en: "Privacy") }
            static var membership: String { L10n.text(zhHans: "会员", en: "Membership") }
            static var stats: String { L10n.text(zhHans: "统计", en: "Stats") }
        }

        enum Skills {
            static var title: String { Tabs.skills }
            static var subtitle: String {
                L10n.text(
                    key: "settings.skills.subtitle",
                    zhHans: "把技能中心和技能设置统一到一个页面里，直接管理开关、获取、更新与卸载。",
                    en: "Manage your skills in one place, including toggles, installs, updates, and uninstalls."
                )
            }
            static var managementHint: String {
                L10n.text(
                    key: "settings.skills.management_hint",
                    zhHans: "在这里统一管理已安装技能、发现新技能，以及调整每个技能的开关。",
                    en: "Manage installed skills, discover new ones, and turn each skill on or off."
                )
            }
        }

        enum KnowledgeBase {
            static var title: String { Tabs.knowledgeBase }
            static var notionTokenPlaceholder: String {
                L10n.text(
                    key: "settings.knowledge_base.notion_token_placeholder",
                    zhHans: "输入 Notion Integration Token",
                    en: "Paste your Notion integration token"
                )
            }
            static var autoSyncCheckbox: String {
                L10n.text(
                    key: "settings.knowledge_base.auto_sync_checkbox",
                    zhHans: "自动后台同步 Notion",
                    en: "Sync Notion automatically in the background"
                )
            }
            static var addFilesButton: String {
                L10n.text(zhHans: "添加文件", en: "Add files")
            }
            static var syncButton: String {
                L10n.text(zhHans: "同步 Notion", en: "Sync Notion")
            }
            static var waitingForToken: String {
                L10n.text(
                    key: "settings.knowledge_base.waiting_for_token",
                    zhHans: "填好 Notion Token 后会自动做后台增量同步。",
                    en: "Background sync starts automatically after you add a Notion token."
                )
            }
        }

        enum AI {
            static var provider: String { L10n.text(zhHans: "服务商", en: "Provider") }
            static var model: String { L10n.text(zhHans: "模型", en: "Model") }
            static var apiKeyPlaceholder: String { L10n.text(zhHans: "输入 API Key", en: "Enter API key") }
            static var testConnection: String { L10n.text(zhHans: "测试连接", en: "Test connection") }
            static var configHint: String {
                L10n.text(
                    key: "settings.ai.config_hint",
                    zhHans: "说明：修改配置后，点一次“测试连接”。测试通过就会立即生效。",
                    en: "After you change these settings, click Test connection. If the test succeeds, the changes apply immediately."
                )
            }
        }

        enum Shortcuts {
            static var recordButton: String {
                L10n.text(key: "settings.shortcuts.record_button", zhHans: "录制快捷键", en: "Record shortcut")
            }
            static var resetButton: String {
                L10n.text(key: "settings.shortcuts.reset_button", zhHans: "恢复默认", en: "Restore default")
            }
            static var testButton: String {
                L10n.text(key: "settings.shortcuts.test_button", zhHans: "测试截图", en: "Test screenshot")
            }
        }

        enum Privacy {
            static var sectionHint: String {
                L10n.text(
                    key: "settings.privacy.section_hint",
                    zhHans: "先完成必要权限授权，其它权限按需开启。",
                    en: "Grant the required permissions first. You can enable the rest only when you need them."
                )
            }
            static var authorize: String {
                L10n.text(key: "settings.privacy.authorize", zhHans: "授权", en: "Grant Access")
            }
            static var openSettings: String {
                L10n.text(key: "settings.privacy.open_settings", zhHans: "打开设置", en: "Open Settings")
            }
            static var refreshStatus: String {
                L10n.text(key: "settings.privacy.refresh_status", zhHans: "刷新权限状态", en: "Refresh status")
            }
            static var authorizeRequired: String {
                L10n.text(key: "settings.privacy.authorize_required", zhHans: "一键授权必要权限", en: "Grant required permissions")
            }
            static var accessibilityTitle: String {
                L10n.text(key: "settings.privacy.accessibility_title", zhHans: "辅助功能", en: "Accessibility")
            }
            static var accessibilityDescription: String {
                L10n.text(
                    key: "settings.privacy.accessibility_description",
                    zhHans: "允许 NexHub 读取选区焦点并与当前应用协同完成浮条交互。",
                    en: "Lets NexHub read your selection and show the floating toolbar in the app you're using."
                )
            }
            static var calendarTitle: String {
                L10n.text(key: "settings.privacy.calendar_title", zhHans: "日历", en: "Calendar")
            }
            static var calendarDescription: String {
                L10n.text(
                    key: "settings.privacy.calendar_description",
                    zhHans: "创建日程技能写入系统日历前，需要授权访问你的日历数据。",
                    en: "Required before schedule skills can add events to your calendar."
                )
            }
            static var automationTitle: String {
                L10n.text(key: "settings.privacy.automation_title", zhHans: "自动化 (Calendar)", en: "Automation (Calendar)")
            }
            static var automationDescription: String {
                L10n.text(
                    key: "settings.privacy.automation_description",
                    zhHans: "首次与日历发生自动化交互时，需要在系统弹窗里允许 Calendar 自动化。",
                    en: "Needed the first time NexHub controls Calendar through a macOS automation prompt."
                )
            }
            static var inputMonitoringTitle: String {
                L10n.text(key: "settings.privacy.input_monitoring_title", zhHans: "输入监控", en: "Input Monitoring")
            }
            static var inputMonitoringDescription: String {
                L10n.text(
                    key: "settings.privacy.input_monitoring_description",
                    zhHans: "当前默认流程不依赖该权限；如需排查系统级输入监听，可直接打开设置。",
                    en: "Not required for the default flow. Open System Settings only if you need to troubleshoot system-level input monitoring."
                )
            }
            static var screenRecordingTitle: String {
                L10n.text(key: "settings.privacy.screen_recording_title", zhHans: "屏幕录制", en: "Screen Recording")
            }
            static var screenRecordingDescription: String {
                L10n.text(
                    key: "settings.privacy.screen_recording_description",
                    zhHans: "当前默认流程不依赖该权限；如需屏幕录制能力，可直接打开系统设置。",
                    en: "Not required for the default flow. Open System Settings only if you need screen capture."
                )
            }
            static var filesAndFoldersTitle: String {
                L10n.text(key: "settings.privacy.files_and_folders_title", zhHans: "文件与文件夹", en: "Files & Folders")
            }
            static var filesAndFoldersDescription: String {
                L10n.text(
                    key: "settings.privacy.files_and_folders_description",
                    zhHans: "通常不需要单独授权；如 Finder 读取受限，可在系统里查看文件访问权限。",
                    en: "Usually not needed. If Finder access is limited, check file permissions in System Settings."
                )
            }
            static var fullDiskAccessTitle: String {
                L10n.text(key: "settings.privacy.full_disk_access_title", zhHans: "完全磁盘访问", en: "Full Disk Access")
            }
            static var fullDiskAccessDescription: String {
                L10n.text(
                    key: "settings.privacy.full_disk_access_description",
                    zhHans: "仅在访问受保护目录时可能需要；大多数日常使用场景无需打开。",
                    en: "Only needed when accessing protected folders. Most people will not need it."
                )
            }
        }

        enum Membership {
            static var title: String { Tabs.membership }
            static var inviteCode: String {
                L10n.text(key: "settings.membership.invite_code", zhHans: "邀请码", en: "Invite Code")
            }
            static var invitePlaceholder: String {
                L10n.text(zhHans: "输入邀请码，例如 NEXHUB-XXXX-XXXX", en: "Enter an invite code, for example NEXHUB-XXXX-XXXX")
            }
            static var redeemInvite: String {
                L10n.text(key: "settings.membership.redeem_invite", zhHans: "兑换邀请码", en: "Redeem Code")
            }
            static var planLabel: String {
                L10n.text(key: "settings.membership.plan_label", zhHans: "订阅计划", en: "Plan")
            }
            static var historyLabel: String {
                L10n.text(key: "settings.membership.history_label", zhHans: "兑换记录", en: "Redemption History")
            }
            static var purchaseComing: String {
                L10n.text(key: "settings.membership.purchase_coming", zhHans: "购买入口接入中", en: "Checkout coming soon")
            }
            static var refreshEntitlement: String {
                L10n.text(key: "settings.membership.refresh_entitlement", zhHans: "刷新权益状态", en: "Refresh Access")
            }
        }

        enum Stats {
            static var title: String { Tabs.stats }
            static var skillUsage: String {
                L10n.text(key: "settings.stats.skill_usage", zhHans: "功能使用", en: "Usage")
            }
            static var appScenes: String {
                L10n.text(key: "settings.stats.app_scenes", zhHans: "常用 App 场景", en: "Top Apps")
            }
            static var contentScenes: String {
                L10n.text(key: "settings.stats.content_scenes", zhHans: "常见内容场景", en: "Top Content Categories")
            }
        }

        enum General {
            static func compatibilityAppsSummary(names: [String], totalCount: Int) -> String {
                let summary = L10n.joinedList(names)
                if totalCount > names.count {
                    return L10n.format(
                        key: "settings.general.compatibility_apps_summary_more",
                        zhHans: "当前兼容抓取应用：%@ 等 %d 个。",
                        en: "Compatible apps: %@ and %d more.",
                        summary,
                        totalCount - names.count
                    )
                }
                return L10n.format(
                    key: "settings.general.compatibility_apps_summary",
                    zhHans: "当前兼容抓取应用：%@。",
                    en: "Compatible apps: %@.",
                    summary
                )
            }
        }
    }
}
