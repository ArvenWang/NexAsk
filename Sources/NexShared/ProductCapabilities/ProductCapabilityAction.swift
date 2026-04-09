import Foundation

enum ProductCapabilityKind: String, Codable {
    case screenshot
    case calendar
    case system
}

enum ProductCapabilityAvailability: String, Codable {
    case available
    case unavailable
    case hidden
}

struct ProductCapabilityInvocationContext: Codable, Equatable {
    let source: ActivationSource?
    let artifactPath: String?
    let sourceBundleID: String?
}

struct ProductCapabilityAction: Codable, Equatable {
    let id: String
    let kind: ProductCapabilityKind
    let label: String
    let icon: String
    let availability: ProductCapabilityAvailability
    let invocationContext: ProductCapabilityInvocationContext
}
