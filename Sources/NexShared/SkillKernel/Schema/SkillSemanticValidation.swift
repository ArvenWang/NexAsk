import Foundation

enum SkillSemanticValidationError: Error, Equatable {
    case missingSkillID
    case missingLabel
    case invalidFollowupDepth
}

enum SkillSemanticValidation {
    static func validate(followup: SkillFollowupContract) throws {
        if followup.skillID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SkillSemanticValidationError.missingSkillID
        }
        if followup.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SkillSemanticValidationError.missingLabel
        }
        if let maxDepth = followup.maxDepth, maxDepth < 0 {
            throw SkillSemanticValidationError.invalidFollowupDepth
        }
    }
}
