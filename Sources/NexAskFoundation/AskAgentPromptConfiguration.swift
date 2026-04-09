import Foundation

package struct AskAgentPromptConfiguration: Equatable {
    package let customSystemPrompt: String?
    package let appendSystemPrompt: String?
    package let overrideSystemPrompt: String?

    package static let `default` = AskAgentPromptConfiguration(
        customSystemPrompt: nil,
        appendSystemPrompt: nil,
        overrideSystemPrompt: nil
    )

    package init(
        customSystemPrompt: String?,
        appendSystemPrompt: String?,
        overrideSystemPrompt: String?
    ) {
        self.customSystemPrompt = customSystemPrompt
        self.appendSystemPrompt = appendSystemPrompt
        self.overrideSystemPrompt = overrideSystemPrompt
    }

    package func merging(_ override: AskAgentPromptConfiguration) -> AskAgentPromptConfiguration {
        AskAgentPromptConfiguration(
            customSystemPrompt: override.customSystemPrompt ?? customSystemPrompt,
            appendSystemPrompt: Self.mergedAppendSystemPrompt(
                base: appendSystemPrompt,
                override: override.appendSystemPrompt
            ),
            overrideSystemPrompt: override.overrideSystemPrompt ?? overrideSystemPrompt
        )
    }

    package static func from(metadata: [String: String]) -> AskAgentPromptConfiguration {
        AskAgentPromptConfiguration(
            customSystemPrompt: firstNonEmptyValue(
                in: metadata,
                keys: [
                    "agent_custom_system_prompt",
                    "ask_custom_system_prompt",
                    "custom_system_prompt"
                ]
            ),
            appendSystemPrompt: firstNonEmptyValue(
                in: metadata,
                keys: [
                    "agent_append_system_prompt",
                    "ask_append_system_prompt",
                    "append_system_prompt"
                ]
            ),
            overrideSystemPrompt: firstNonEmptyValue(
                in: metadata,
                keys: [
                    "agent_override_system_prompt",
                    "ask_override_system_prompt",
                    "override_system_prompt"
                ]
            )
        )
    }

    private static func mergedAppendSystemPrompt(base: String?, override: String?) -> String? {
        let sections = [base, override].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private static func firstNonEmptyValue(
        in metadata: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }
}
