import Foundation

enum SkillPromptComposer {
    static func composeSystemPrompt(
        instructionText: String?,
        fallback: String,
        appendedSections: [String] = []
    ) -> String {
        let base = normalizedSection(instructionText) ?? normalizedSection(fallback) ?? fallback
        let extras = appendedSections.compactMap(normalizedSection)
        guard !extras.isEmpty else { return base }
        return ([base] + extras).joined(separator: "\n\n")
    }

    static func composeUserPrompt(sections: [String?]) -> String {
        sections
            .compactMap(normalizedSection)
            .joined(separator: "\n\n")
    }

    private static func normalizedSection(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
