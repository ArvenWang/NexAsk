import Foundation

struct RouteSkillDiagnostic {
    let skillID: String
    let title: String
    let ruleScore: Double
    let usageScore: Double
    let finalScore: Double
    let reason: String
}

struct RouteDiagnosticsSnapshot {
    let selectionPreview: String
    let bundleID: String?
    let sourceInteractionContext: SourceInteractionContext
    let contentCategory: String
    let confidence: Double
    let recommendationStyle: SkillRecommendationStyle
    let recommendationReason: String
    let primarySkillIDs: [String]
    let secondarySkillIDs: [String]
    let diagnostics: [RouteSkillDiagnostic]
    let timestamp: Date
}

final class RouteDiagnosticsStore {
    static let shared = RouteDiagnosticsStore()

    private let queue = DispatchQueue(label: "com.nexhub.route-diagnostics", qos: .utility)
    private var latestSnapshot: RouteDiagnosticsSnapshot?

    private init() {}

    func update(_ snapshot: RouteDiagnosticsSnapshot?) {
        queue.async {
            self.latestSnapshot = snapshot
        }
    }

    func currentSnapshot() -> RouteDiagnosticsSnapshot? {
        queue.sync { latestSnapshot }
    }
}
