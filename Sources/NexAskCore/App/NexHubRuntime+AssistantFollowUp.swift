import AppKit
import NexShared
import UserNotifications

#if !NEXHUB_PRODUCT_NEXHUB

extension Notification.Name {
    static var nexhubOpenAssistantFollowUp: Notification.Name {
        AppBrand.productNotificationName("openAssistantFollowUp")
    }
}

extension NexHubRuntime {
    @objc func handleOpenAssistantFollowUpNotification(_ notification: Notification) {
        _ = notification
    }

    func beginAskAssistantFollowUp(from activation: AskAssistantFollowUpActivation) {
        (productExperienceController as? AskProductExperienceController)?
            .beginAskAssistantFollowUp(from: activation)
    }
}

#endif
