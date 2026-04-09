import AppKit
import ObjectiveC.runtime
import UserNotifications

package protocol AppProductExperienceController: NSObjectProtocol, UNUserNotificationCenterDelegate {
    var isSelectionOverlayActive: Bool { get }
    var isConversationVisible: Bool { get }

    func applicationDidFinishLaunching()
    func applicationWillTerminate()
    func handleSelectionSnapshot(_ snapshot: SelectionSnapshot)
    func handleSelectionCleared()
    func handleFileSelectionSnapshot(_ snapshot: FileSelectionSnapshot)
    func handleKnowledgeBaseDidChange()
    func handleApplicationDidBecomeActive()
    func handleRuntimeSettingsChanged()
    func dismissSelection()
    func dismissConversation()
    func contains(screenPoint: CGPoint) -> Bool

    @discardableResult
    func presentPrimaryStatusItemExperience(anchorFrame: CGRect?) -> Bool
}

package final class DefaultAppProductExperienceController: NSObject, AppProductExperienceController {
    package var isSelectionOverlayActive: Bool { false }
    package var isConversationVisible: Bool { false }

    package func applicationDidFinishLaunching() {}
    package func applicationWillTerminate() {}
    package func handleSelectionSnapshot(_ snapshot: SelectionSnapshot) { _ = snapshot }
    package func handleSelectionCleared() {}
    package func handleFileSelectionSnapshot(_ snapshot: FileSelectionSnapshot) { _ = snapshot }
    package func handleKnowledgeBaseDidChange() {}
    package func handleApplicationDidBecomeActive() {}
    package func handleRuntimeSettingsChanged() {}
    package func dismissSelection() {}
    package func dismissConversation() {}
    package func contains(screenPoint: CGPoint) -> Bool {
        _ = screenPoint
        return false
    }

    @discardableResult
    package func presentPrimaryStatusItemExperience(anchorFrame: CGRect?) -> Bool {
        _ = anchorFrame
        return false
    }
}

package enum AppProductFeatureRegistry {
    package static var makeExperienceController: (NexHubRuntime) -> any AppProductExperienceController = { _ in
        DefaultAppProductExperienceController()
    }

    package static var makeAutomationPageView: () -> any SettingsAutomationPageView = {
        DefaultSettingsAutomationPageView()
    }
}

private enum AppProductExperienceControllerAssociation {
    static var key: UInt8 = 0
}

extension NexHubRuntime {
    package var productExperienceController: any AppProductExperienceController {
        if let controller = objc_getAssociatedObject(
            self,
            &AppProductExperienceControllerAssociation.key
        ) as? any AppProductExperienceController {
            return controller
        }

        let controller = AppProductFeatureRegistry.makeExperienceController(self)
        objc_setAssociatedObject(
            self,
            &AppProductExperienceControllerAssociation.key,
            controller as AnyObject,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return controller
    }
}
