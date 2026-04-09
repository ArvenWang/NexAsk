import AppKit
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB

extension NexHubRuntime {
    private var askProductExperienceController: AskProductExperienceController? {
        productExperienceController as? AskProductExperienceController
    }

    func handleAskBoxCaptureBegan(at point: CGPoint) {
        askProductExperienceController?.handleAskBoxCaptureBegan(at: point)
    }

    func handleAskBoxCaptureChanged(to point: CGPoint) {
        askProductExperienceController?.handleAskBoxCaptureChanged(to: point)
    }

    func handleAskBoxCaptureEnded(at point: CGPoint) {
        askProductExperienceController?.handleAskBoxCaptureEnded(at: point)
    }

    func handleAskBoxCaptureCancelled() {
        askProductExperienceController?.handleAskBoxCaptureCancelled()
    }

    func beginAskConversation(from selection: AskBoxSelection) {
        askProductExperienceController?.beginAskConversation(from: selection)
    }

    func beginAskAssistantFollowUp(from item: AskInboxItem) {
        askProductExperienceController?.beginAskAssistantFollowUp(from: item)
    }

    func dismissAskConversation() {
        askProductExperienceController?.dismissConversation()
    }

    func dismissAskSelection() {
        askProductExperienceController?.dismissSelection()
    }
}

#endif
