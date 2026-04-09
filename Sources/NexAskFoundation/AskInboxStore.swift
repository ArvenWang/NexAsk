import Foundation

package final class AskInboxStore {
    package static let shared = AskInboxStore()

    private let automationStore: AskAutomationStore

    package init(automationStore: AskAutomationStore = .shared) {
        self.automationStore = automationStore
    }

    package func items(limit: Int = 40) -> [AskInboxItem] {
        automationStore.listInboxItems(limit: limit)
    }

    package func save(_ item: AskInboxItem) {
        automationStore.saveInboxItem(item)
    }

    package func markRead(_ id: String) {
        _ = automationStore.markInboxItemRead(id)
    }
}
