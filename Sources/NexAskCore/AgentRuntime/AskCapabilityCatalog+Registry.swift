import NexAskFoundation

typealias AskCapabilityCatalog = NexAskFoundation.AskCapabilityCatalog

extension AskCapabilityCatalog {
    static func defaultRegistry() -> AskStaticCapabilityRegistry {
        AskStaticCapabilityRegistry(catalog: defaultCatalog())
    }
}
