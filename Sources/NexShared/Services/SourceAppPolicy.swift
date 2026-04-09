import Foundation

package enum SourceAppReplaceSupportMode: String {
    case standard
    case keyboardSelectionFallback
    case editableTargetOnly
}

package enum SourceAppWritebackMode: String, Equatable {
    case none
    case composerPaste
    case composerAssisted
}

package enum DeliveryTargetSurface: String, Equatable {
    case unavailable
    case chatComposer
}

package enum ReplaceTargetAvailability: String, Equatable {
    case unavailable
    case capturedEditableSelection
    case keyboardSelectionFallback
}

package enum SourceInteractionSurface: String, Equatable {
    case editableSelection
    case textSelection
    case fileSelection
    case imageCapture
    case detached
}

package enum SourceAppFamily: String, Equatable {
    case wechat
    case wework
    case qq
    case lark
    case other
}

package struct DeliveryTargetContext: Equatable {
    let surface: DeliveryTargetSurface
    let writebackMode: SourceAppWritebackMode
    let supportsWriteback: Bool
}

package struct ReplaceTargetContext: Equatable {
    let mode: SourceAppReplaceSupportMode
    let availability: ReplaceTargetAvailability
    let supportsReplaceSelection: Bool
}

package struct SourceInteractionContext: Equatable {
    let bundleID: String?
    let family: SourceAppFamily
    let surface: SourceInteractionSurface
    let deliveryTarget: DeliveryTargetContext
    let replaceTarget: ReplaceTargetContext

    init(
        source: ActivationSource = .selectedText,
        bundleID: String?,
        supportsReplaceSelection: Bool,
        hasCapturedReplacementTarget: Bool
    ) {
        let surface = SourceAppPolicy.surface(
            for: source,
            hasCapturedReplacementTarget: hasCapturedReplacementTarget
        )
        let writebackMode = SourceAppPolicy.writebackMode(
            bundleID: bundleID,
            surface: surface
        )
        let replaceMode = SourceAppPolicy.replaceSupportMode(bundleID: bundleID)
        self.bundleID = bundleID
        self.family = SourceAppPolicy.family(for: bundleID)
        self.surface = surface
        self.deliveryTarget = DeliveryTargetContext(
            surface: writebackMode == .none ? .unavailable : .chatComposer,
            writebackMode: writebackMode,
            supportsWriteback: writebackMode != .none
        )
        self.replaceTarget = ReplaceTargetContext(
            mode: replaceMode,
            availability: SourceAppPolicy.replaceTargetAvailability(
                replaceMode: replaceMode,
                supportsReplaceSelection: supportsReplaceSelection,
                hasCapturedReplacementTarget: hasCapturedReplacementTarget
            ),
            supportsReplaceSelection: supportsReplaceSelection
        )
    }

    static var empty: SourceInteractionContext {
        SourceInteractionContext(
            source: .mixedContext,
            bundleID: nil,
            supportsReplaceSelection: false,
            hasCapturedReplacementTarget: false
        )
    }

    var writebackMode: SourceAppWritebackMode {
        deliveryTarget.writebackMode
    }

    var supportsMessageWriteback: Bool {
        deliveryTarget.supportsWriteback
    }

    var replaceSupportMode: SourceAppReplaceSupportMode {
        replaceTarget.mode
    }

    var hasCapturedReplacementTarget: Bool {
        replaceTarget.availability == .capturedEditableSelection
    }

    var supportsReplaceSelection: Bool {
        replaceTarget.supportsReplaceSelection
    }
}

enum SourceAppPolicy {
    static func family(for bundleID: String?) -> SourceAppFamily {
        guard let normalized = normalizedBundleID(bundleID) else {
            return .other
        }

        switch normalized {
        case "com.tencent.xinwechat":
            return .wechat
        case "com.tencent.weworkmac":
            return .wework
        case "com.tencent.qq", "com.tencent.tim":
            return .qq
        case "com.bytedance.feishu", "com.electron.lark", "com.larksuite.suite":
            return .lark
        default:
            return .other
        }
    }

    static func supportsMessageWriteback(
        bundleID: String?,
        surface: SourceInteractionSurface = .textSelection
    ) -> Bool {
        writebackMode(bundleID: bundleID, surface: surface) != .none
    }

    static func writebackMode(
        bundleID: String?,
        surface: SourceInteractionSurface = .textSelection
    ) -> SourceAppWritebackMode {
        guard surface == .textSelection || surface == .editableSelection else {
            return .none
        }
        guard let normalized = normalizedBundleID(bundleID) else { return .none }

        switch family(for: normalized) {
        case .wechat, .qq:
            return .composerPaste
        case .wework, .lark:
            return .composerAssisted
        case .other:
            let patterns = [
                "tencent.qq",
                "xinwechat",
                "wework",
                "electron.lark",
                "bytedance.feishu",
                "larksuite",
                "feishu",
            ]
            guard let pattern = patterns.first(where: { normalized.contains($0) }) else {
                return .none
            }
            if pattern.contains("qq") || pattern.contains("xinwechat") {
                return .composerPaste
            }
            return .composerAssisted
        }
    }

    static func supportsContainerReplacementInference(bundleID: String?) -> Bool {
        switch family(for: bundleID) {
        case .wechat, .lark:
            return true
        case .wework, .qq, .other:
            return false
        }
    }

    static func replaceSupportMode(bundleID: String?) -> SourceAppReplaceSupportMode {
        switch family(for: bundleID) {
        case .wechat:
            return .editableTargetOnly
        case .lark:
            return .keyboardSelectionFallback
        case .wework, .qq, .other:
            return .standard
        }
    }

    static func interactionContext(
        source: ActivationSource,
        bundleID: String?,
        replacementTarget: ReplacementTargetSnapshot?,
        selectedText: String?
    ) -> SourceInteractionContext {
        let hasCapturedReplacementTarget = replacementTarget?.hasEditableSelection == true
        return SourceInteractionContext(
            source: source,
            bundleID: bundleID,
            supportsReplaceSelection: hasCapturedReplacementTarget && SelectionAccess.supportsReplacingSelectedText(
                sourceBundleID: bundleID,
                replacementTarget: replacementTarget,
                selectedText: selectedText
            ),
            hasCapturedReplacementTarget: hasCapturedReplacementTarget
        )
    }

    static func surface(
        for source: ActivationSource,
        hasCapturedReplacementTarget: Bool
    ) -> SourceInteractionSurface {
        switch source {
        case .selectedText, .clipboardText, .url, .inputBoxContext, .mixedContext:
            return hasCapturedReplacementTarget ? .editableSelection : .textSelection
        case .fileSelection:
            return .fileSelection
        case .screenshotRegion, .imageCapture:
            return .imageCapture
        }
    }

    static func replaceTargetAvailability(
        replaceMode: SourceAppReplaceSupportMode,
        supportsReplaceSelection: Bool,
        hasCapturedReplacementTarget: Bool
    ) -> ReplaceTargetAvailability {
        if hasCapturedReplacementTarget {
            return .capturedEditableSelection
        }
        if supportsReplaceSelection, replaceMode == .keyboardSelectionFallback {
            return .keyboardSelectionFallback
        }
        return .unavailable
    }

    private static func normalizedBundleID(_ bundleID: String?) -> String? {
        let normalized = bundleID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }
}
