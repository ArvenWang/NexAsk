import Foundation
import NexShared

struct AskMCPToolProvider: AskToolProviding {
    private let resourceCatalog: any AskMCPResourceCatalogProviding
    private let connectionStore: AskMCPConnectionStore

    init(
        resourceCatalog: any AskMCPResourceCatalogProviding = AskNoopMCPResourceCatalog(),
        connectionStore: AskMCPConnectionStore = .shared
    ) {
        self.resourceCatalog = resourceCatalog
        self.connectionStore = connectionStore
    }

    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        let hasKnownConnections = resourceCatalog.hasAvailableResources || !connectionStore.listConnections().isEmpty
        guard hasKnownConnections else {
            return []
        }
        let responseLanguage = context.responseLanguage
        let hasMirroredResources = !resourceCatalog.listResources(serverName: nil).isEmpty
        var tools: [AskToolDefinition] = [
            AskToolDefinition(
                name: "list_mcp_resources",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "列出当前已连接 MCP 资源目录中的可读资源。",
                    en: "List the readable resources exposed by the currently connected MCP catalog."
                ),
                parameters: objectSchema(
                    properties: [
                        "server": stringSchema("Optional MCP server name to scope the listing.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "read_mcp_resource",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "读取一个 MCP 资源内容。需要提供 server 和 uri。",
                    en: "Read the contents of an MCP resource. Pass both server and uri."
                ),
                parameters: objectSchema(
                    properties: [
                        "server": stringSchema("The MCP server name that owns the resource."),
                        "uri": stringSchema("The MCP resource URI to read.")
                    ],
                    required: ["server", "uri"]
                )
            )
        ]
        if !hasMirroredResources {
            tools.removeAll { $0.name == "read_mcp_resource" }
        }
        return tools
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
}
