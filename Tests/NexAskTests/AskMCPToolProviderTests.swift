import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskMCPToolProviderTests: XCTestCase {
    func testProviderExposesListToolWhenConnectionExistsWithoutMirroredResources() throws {
        let root = makeRootDirectory()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
        _ = connectionStore.upsert(
            AskMCPConnectionRecord(
                serverName: "Docs",
                status: .connected,
                readableResourceCount: 0
            )
        )
        let catalog = AskSharedMCPResourceCatalog(
            notificationCenter: NotificationCenter(),
            persistToDisk: false,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )
        let provider = AskMCPToolProvider(
            resourceCatalog: catalog,
            connectionStore: connectionStore
        )

        let names = Set(provider.availableTools(context: .minimal(responseLanguage: "zh")).map(\.name))

        XCTAssertEqual(names, ["list_mcp_resources"])
    }

    func testProviderRefreshesReadToolWhenMirroredResourcesAppearOrDisappear() throws {
        let root = makeRootDirectory()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
        _ = connectionStore.upsert(
            AskMCPConnectionRecord(
                serverName: "Docs",
                status: .connected,
                readableResourceCount: 0
            )
        )
        let catalog = AskSharedMCPResourceCatalog(
            notificationCenter: NotificationCenter(),
            persistToDisk: false,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )
        let provider = AskMCPToolProvider(
            resourceCatalog: catalog,
            connectionStore: connectionStore
        )

        XCTAssertEqual(
            Set(provider.availableTools(context: .minimal(responseLanguage: "zh")).map(\.name)),
            ["list_mcp_resources"]
        )

        catalog.replaceResources(
            serverName: "Docs",
            resources: [
                AskMCPResourceRecord(
                    serverName: "Docs",
                    uri: "mcp://docs/spec",
                    name: "Spec",
                    description: nil,
                    mimeType: "text/markdown",
                    textContent: "# Spec",
                    updatedAt: Date(),
                    metadata: [:]
                )
            ]
        )

        XCTAssertEqual(
            Set(provider.availableTools(context: .minimal(responseLanguage: "zh")).map(\.name)),
            ["list_mcp_resources", "read_mcp_resource"]
        )

        catalog.clear()

        XCTAssertEqual(
            Set(provider.availableTools(context: .minimal(responseLanguage: "zh")).map(\.name)),
            ["list_mcp_resources"]
        )
    }

    private func makeRootDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-mcp-tool-provider-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to prepare MCP tool provider root: \(error)", file: file, line: line)
        }
        return root
    }
}
