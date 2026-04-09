import Foundation

enum CapabilityActionResolver {
    static func resolve(
        resultEnvelope: SkillResultEnvelope,
        definition: SkillDefinition?
    ) -> [ResultFooterAction] {
        guard let definition else { return [] }

        // Capability actions are modeled separately from Skill follow-ups even when
        // the current UI still flattens them into the same footer button row.
        switch definition.skillID {
        case "schedule":
            return []
        default:
            return []
        }
    }
}
