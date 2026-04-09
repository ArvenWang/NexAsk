import Foundation
import NexShared

struct AskLocalToolProvider: AskToolProviding {
    private let playgroundStore: AskPlaygroundStore
    private let descriptorsProvider: (() -> [AskLocalPromotedToolDescriptor])?

    init(
        playgroundStore: AskPlaygroundStore = .shared,
        descriptorsProvider: (() -> [AskLocalPromotedToolDescriptor])? = nil
    ) {
        self.playgroundStore = playgroundStore
        self.descriptorsProvider = descriptorsProvider
    }

    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        let descriptors = descriptorsProvider?() ?? playgroundStore.promotedToolDescriptors()
        return descriptors.map { descriptor in
            AskToolDefinition(
                name: descriptor.id,
                description: localizedDescription(for: descriptor, languageCode: context.responseLanguage),
                parameters: objectSchema(
                    properties: [
                        "input": stringSchema("Optional text input to pass into the promoted local tool."),
                        "open_result": boolSchema("Whether ASK should open the generated result after the tool finishes. Default false.")
                    ]
                )
            )
        }
    }

    private func localizedDescription(
        for descriptor: AskLocalPromotedToolDescriptor,
        languageCode: String
    ) -> String {
        let title = descriptor.name.replacingOccurrences(of: "_", with: " ")
        let base = L10n.format(
            languageCode: languageCode,
            zhHans: "运行一个之前在 Playground 中沉淀并已提升为本地工具的资产：%@。",
            en: "Run a previously created Playground asset that was promoted into a local ASK tool: %@.",
            title
        )
        let summary = descriptor.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? base : "\(base) \(summary)"
    }

    private func objectSchema(
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private func stringSchema(_ description: String) -> [String: Any] {
        [
            "type": "string",
            "description": description
        ]
    }

    private func boolSchema(_ description: String) -> [String: Any] {
        [
            "type": "boolean",
            "description": description
        ]
    }
}
