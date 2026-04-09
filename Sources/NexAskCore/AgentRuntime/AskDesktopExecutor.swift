import AppKit
import Foundation
import NexShared

struct AskDesktopExecutor: AskCapabilityExecuting {
    let supportedCapabilityIDs: [AskCapabilityID] = [
        "desktop.snapshot_directory",
        "desktop.open_path",
        "desktop.reveal_in_finder",
        "desktop.stage_move_operation",
        "desktop.commit_move_operation",
        "desktop.cancel_move_operation"
    ]

    private let fileManager: FileManager
    private let homeDirectoryProvider: () -> URL
    private let operationStore: AskDesktopOperationStore

    init(
        fileManager: FileManager = .default,
        homeDirectoryProvider: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.fileManager = fileManager
        self.homeDirectoryProvider = homeDirectoryProvider
        self.operationStore = AskDesktopOperationStore()
    }

    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        switch request.capability.id {
        case "desktop.snapshot_directory":
            return snapshotDirectory(request: request)
        case "desktop.open_path":
            return await openPath(request: request)
        case "desktop.reveal_in_finder":
            return await revealInFinder(request: request)
        case "desktop.stage_move_operation":
            return await stageMoveOperation(request: request)
        case "desktop.commit_move_operation":
            return await commitMoveOperation(request: request)
        case "desktop.cancel_move_operation":
            return await cancelMoveOperation(request: request)
        default:
            return .unsupported(summary: "Unsupported desktop capability: \(request.capability.id)")
        }
    }

    private func snapshotDirectory(request: AskCapabilityExecutionRequest) -> AskCapabilityExecutionResult {
        let roots = resolvedRoots(from: request.arguments)
        guard !roots.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No readable directory was provided for the snapshot.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let criteria = SnapshotCriteria(
            roots: roots,
            extensionFilters: parsedExtensions(from: request.arguments),
            nameContains: firstNonEmptyValue(in: request.arguments, keys: ["name_contains", "query", "filename"]),
            directChildrenOnly: boolValue(in: request.arguments, keys: ["direct_children_only", "shallow"]) ?? false,
            includeDirectories: boolValue(in: request.arguments, keys: ["include_directories"]) ?? false
        )
        let matches = findMatches(criteria: criteria)
        let rootListing = criteria.roots.map(\.path).joined(separator: "\n")
        let matchListing = matches.map(\.path).joined(separator: "\n")

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: matches.isEmpty
                ? "Created a directory snapshot with no matching items."
                : "Created a directory snapshot with \(matches.count) matching item(s).",
            approvalID: nil,
            artifacts: matchListing.isEmpty ? [] : [AskCapabilityArtifact(kind: "snapshot_paths", value: matchListing)],
            metadata: [
                "root_directories": rootListing,
                "direct_children_only": String(criteria.directChildrenOnly),
                "include_directories": String(criteria.includeDirectories),
                "extensions": criteria.extensionFilters.joined(separator: ","),
                "name_contains": criteria.nameContains ?? "",
                "match_count": String(matches.count)
            ]
        )
    }

    private func openPath(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let url = resolvedPath(
            firstNonEmptyValue(in: request.arguments, keys: ["path", "file", "directory", "target_path"])
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No valid local path was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let existence = fileMetadata(for: url)
        guard existence.exists else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The requested local path does not exist.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "path": url.path
                ]
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to open the requested path.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "path", value: url.path)],
                metadata: [
                    "path": url.path,
                    "is_directory": String(existence.isDirectory),
                    "dry_run": "true"
                ]
            )
        }

        let opened = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        return AskCapabilityExecutionResult(
            status: opened ? .succeeded : .failed,
            summary: opened ? "Opened the requested path." : "Failed to open the requested path.",
            approvalID: nil,
            artifacts: [AskCapabilityArtifact(kind: "path", value: url.path)],
            metadata: [
                "path": url.path,
                "is_directory": String(existence.isDirectory),
                "opened": String(opened)
            ]
        )
    }

    private func revealInFinder(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let url = resolvedPath(
            firstNonEmptyValue(in: request.arguments, keys: ["path", "file", "directory", "target_path"])
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No valid local path was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let existence = fileMetadata(for: url)
        guard existence.exists else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The requested local path does not exist.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "path": url.path
                ]
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to reveal the requested path in Finder.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "path", value: url.path)],
                metadata: [
                    "path": url.path,
                    "is_directory": String(existence.isDirectory),
                    "dry_run": "true"
                ]
            )
        }

        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Revealed the requested path in Finder.",
            approvalID: nil,
            artifacts: [AskCapabilityArtifact(kind: "path", value: url.path)],
            metadata: [
                "path": url.path,
                "is_directory": String(existence.isDirectory),
                "revealed": "true"
            ]
        )
    }

    private func stageMoveOperation(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let destinationDirectory = resolvedPath(
            firstNonEmptyValue(in: request.arguments, keys: ["destination_directory", "target_directory", "directory"])
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No valid destination directory was provided for the move plan.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let rawSourcePaths = stringListValue(in: request.arguments, keys: ["source_paths", "paths", "files"])
        let normalizedSources = uniqueURLs(rawSourcePaths.compactMap(resolvedPath(_:)))
        let existingSources = normalizedSources.filter { fileMetadata(for: $0).exists }
        let skippedPaths = rawSourcePaths.filter { rawPath in
            guard let resolved = resolvedPath(rawPath) else { return true }
            return !existingSources.contains(where: { $0.standardizedFileURL.path == resolved.standardizedFileURL.path })
        }

        guard !existingSources.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No readable source files were found to stage for moving.",
                approvalID: nil,
                artifacts: skippedPaths.isEmpty ? [] : [AskCapabilityArtifact(kind: "skipped_paths", value: skippedPaths.joined(separator: "\n"))],
                metadata: [
                    "destination_directory": destinationDirectory.path,
                    "affected_count": "0",
                    "skipped_count": String(skippedPaths.count)
                ]
            )
        }

        let collisions = existingSources.compactMap { sourceURL -> AskStagedOperationCollision? in
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            guard fileMetadata(for: destinationURL).exists else { return nil }
            return AskStagedOperationCollision(
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path
            )
        }

        let createDestinationIfNeeded = boolValue(
            in: request.arguments,
            keys: ["create_destination_if_needed", "create_if_needed"]
        ) ?? false

        let operation = AskStagedOperation(
            id: UUID().uuidString.lowercased(),
            sessionID: request.task.metadata["session_id"] ?? request.task.id,
            kind: .move,
            sourceSnapshotID: nil,
            selectionID: nil,
            sourcePaths: existingSources.map(\.path),
            destinationDirectoryPath: destinationDirectory.path,
            createDestinationIfNeeded: createDestinationIfNeeded,
            affectedItemCount: existingSources.count,
            previewPaths: Array(existingSources.prefix(5).map(\.path)),
            collisions: collisions,
            skippedPaths: skippedPaths,
            status: .staged,
            createdAt: Date()
        )
        await operationStore.setOperation(operation)

        var artifacts: [AskCapabilityArtifact] = [
            AskCapabilityArtifact(kind: "move_preview_paths", value: operation.previewPaths.joined(separator: "\n"))
        ]
        if !collisions.isEmpty {
            artifacts.append(
                AskCapabilityArtifact(
                    kind: "move_collisions",
                    value: collisions.map { "\($0.sourcePath) -> \($0.destinationPath)" }.joined(separator: "\n")
                )
            )
        }
        if !skippedPaths.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "skipped_paths", value: skippedPaths.joined(separator: "\n")))
        }

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Prepared a local move plan for \(operation.affectedItemCount) item(s).",
            approvalID: nil,
            artifacts: artifacts,
            metadata: [
                "operation_id": operation.id,
                "operation_kind": operation.kind.rawValue,
                "status": operation.status.rawValue,
                "destination_directory": operation.destinationDirectoryPath,
                "create_destination_if_needed": String(operation.createDestinationIfNeeded),
                "affected_count": String(operation.affectedItemCount),
                "collision_count": String(operation.collisions.count),
                "skipped_count": String(operation.skippedPaths.count)
            ]
        )
    }

    private func commitMoveOperation(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let operationID = firstNonEmptyValue(in: request.arguments, keys: ["operation_id"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No staged move operation id was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard var operation = await operationStore.operation(id: operationID) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The requested staged move operation could not be found.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "operation_id": operationID
                ]
            )
        }

        guard operation.status == .staged || operation.status == .awaitingApproval else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "This move operation is no longer in a committable state.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "operation_id": operation.id,
                    "status": operation.status.rawValue
                ]
            )
        }

        let destinationDirectory = URL(fileURLWithPath: operation.destinationDirectoryPath, isDirectory: true)
        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to move \(operation.affectedItemCount) item(s) into \(destinationDirectory.lastPathComponent).",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "move_preview_paths", value: operation.previewPaths.joined(separator: "\n"))
                ],
                metadata: [
                    "operation_id": operation.id,
                    "destination_directory": operation.destinationDirectoryPath,
                    "affected_count": String(operation.affectedItemCount),
                    "dry_run": "true"
                ]
            )
        }

        do {
            if operation.createDestinationIfNeeded {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }
        } catch {
            operation.status = .failed
            await operationStore.setOperation(operation)
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to create the destination directory for the move plan.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "operation_id": operation.id,
                    "destination_directory": operation.destinationDirectoryPath,
                    "status": operation.status.rawValue,
                    "error": error.localizedDescription
                ]
            )
        }

        var movedPaths: [String] = []
        var skippedPaths = operation.skippedPaths
        for sourcePath in operation.sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard fileMetadata(for: sourceURL).exists else {
                skippedPaths.append(sourceURL.path)
                continue
            }

            let destinationURL = uniqueDestinationURL(for: sourceURL, inside: destinationDirectory)
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedPaths.append(destinationURL.path)
            } catch {
                skippedPaths.append(sourceURL.path)
            }
        }

        operation.status = movedPaths.isEmpty ? .failed : .committed
        await operationStore.setOperation(operation)

        var artifacts: [AskCapabilityArtifact] = [
            AskCapabilityArtifact(kind: "destination_directory", value: destinationDirectory.path)
        ]
        if !movedPaths.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "moved_paths", value: movedPaths.prefix(12).joined(separator: "\n")))
        }
        if !skippedPaths.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "skipped_paths", value: skippedPaths.prefix(12).joined(separator: "\n")))
        }

        let summary: String = {
            if movedPaths.isEmpty {
                return "The approved move plan did not move any files."
            }
            if skippedPaths.isEmpty {
                return "Moved \(movedPaths.count) item(s) into \(destinationDirectory.lastPathComponent)."
            }
            return "Moved \(movedPaths.count) item(s) into \(destinationDirectory.lastPathComponent) and skipped \(skippedPaths.count) item(s)."
        }()

        return AskCapabilityExecutionResult(
            status: movedPaths.isEmpty ? .failed : .succeeded,
            summary: summary,
            approvalID: nil,
            artifacts: artifacts,
            metadata: [
                "operation_id": operation.id,
                "destination_directory": operation.destinationDirectoryPath,
                "status": operation.status.rawValue,
                "moved_count": String(movedPaths.count),
                "skipped_count": String(skippedPaths.count),
                "affected_count": String(operation.affectedItemCount)
            ]
        )
    }

    private func cancelMoveOperation(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let operationID = firstNonEmptyValue(in: request.arguments, keys: ["operation_id"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No staged move operation id was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard var operation = await operationStore.operation(id: operationID) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The requested staged move operation could not be found.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "operation_id": operationID
                ]
            )
        }

        operation.status = .cancelled
        await operationStore.setOperation(operation)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Cancelled the staged local move plan.",
            approvalID: nil,
            artifacts: [],
            metadata: [
                "operation_id": operation.id,
                "status": operation.status.rawValue,
                "destination_directory": operation.destinationDirectoryPath,
                "affected_count": String(operation.affectedItemCount)
            ]
        )
    }

    private func resolvedRoots(from arguments: AskInvocationMetadata) -> [URL] {
        let rawRoots = stringListValue(in: arguments, keys: ["root_directories", "directories"])
        let fallbackRoot = firstNonEmptyValue(in: arguments, keys: ["directory", "path", "root", "root_directory"])
        let resolved = (rawRoots.isEmpty ? [fallbackRoot].compactMap { $0 } : rawRoots)
            .compactMap(resolvedPath(_:))
            .filter { fileMetadata(for: $0).exists && fileMetadata(for: $0).isDirectory }
        return uniqueURLs(resolved)
    }

    private func parsedExtensions(from arguments: AskInvocationMetadata) -> [String] {
        let extensions = stringListValue(in: arguments, keys: ["extensions", "file_extensions"])
            .map { value in
                value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: extensions).compactMap { $0 as? String })
    }

    private func resolvedPath(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let home = homeDirectoryProvider()
        if lowercased == "desktop" {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if lowercased == "downloads" {
            return home.appendingPathComponent("Downloads", isDirectory: true)
        }
        if lowercased == "documents" || lowercased == "document" {
            return home.appendingPathComponent("Documents", isDirectory: true)
        }
        if lowercased.hasPrefix("desktop/") {
            return home.appendingPathComponent("Desktop", isDirectory: true).appendingPathComponent(String(trimmed.dropFirst("desktop/".count)))
        }
        if lowercased.hasPrefix("downloads/") {
            return home.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(String(trimmed.dropFirst("downloads/".count)))
        }
        if lowercased.hasPrefix("documents/") {
            return home.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent(String(trimmed.dropFirst("documents/".count)))
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private func fileMetadata(for url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    private func findMatches(criteria: SnapshotCriteria) -> [URL] {
        var matches: [URL] = []
        var inspected = 0
        let normalizedExtensions = Set(criteria.extensionFilters)
        let normalizedNameQuery = criteria.nameContains?.lowercased()

        for root in criteria.roots {
            guard fileMetadata(for: root).exists else { continue }
            if fileMatches(
                root,
                includeDirectories: criteria.includeDirectories,
                normalizedExtensions: normalizedExtensions,
                normalizedNameQuery: normalizedNameQuery
            ) {
                matches.append(root)
            }

            if criteria.directChildrenOnly {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continue
                }
                for child in children {
                    if fileMatches(
                        child,
                        includeDirectories: criteria.includeDirectories,
                        normalizedExtensions: normalizedExtensions,
                        normalizedNameQuery: normalizedNameQuery
                    ) {
                        matches.append(child)
                    }
                }
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            while let item = enumerator.nextObject() as? URL {
                inspected += 1
                if inspected > 5_000 {
                    break
                }
                if fileMatches(
                    item,
                    includeDirectories: criteria.includeDirectories,
                    normalizedExtensions: normalizedExtensions,
                    normalizedNameQuery: normalizedNameQuery
                ) {
                    matches.append(item)
                }
            }

            if inspected > 5_000 {
                break
            }
        }

        return uniqueURLs(matches).sorted { lhs, rhs in
            let lhsDepth = relativeDepth(of: lhs, under: criteria.roots)
            let rhsDepth = relativeDepth(of: rhs, under: criteria.roots)
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private func fileMatches(
        _ url: URL,
        includeDirectories: Bool,
        normalizedExtensions: Set<String>,
        normalizedNameQuery: String?
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]),
              values.isHidden != true else {
            return false
        }

        let isDirectory = values.isDirectory == true
        if isDirectory && !includeDirectories {
            return false
        }

        if !normalizedExtensions.isEmpty {
            if isDirectory {
                return false
            }
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, normalizedExtensions.contains(ext) else {
                return false
            }
        }

        if let normalizedNameQuery, !normalizedNameQuery.isEmpty,
           !url.lastPathComponent.lowercased().contains(normalizedNameQuery) {
            return false
        }

        return isDirectory || values.isRegularFile == true
    }

    private func relativeDepth(of url: URL, under roots: [URL]) -> Int {
        let standardizedPath = url.standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPath) else { continue }
            let suffix = standardizedPath.dropFirst(rootPath.count).split(separator: "/")
            return suffix.count
        }
        return Int.max
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            output.append(url)
        }
        return output
    }

    private func uniqueDestinationURL(for sourceURL: URL, inside destinationDirectory: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        var index = 1

        while fileMetadata(for: candidate).exists {
            let suffix = " \(index)"
            let fileName = ext.isEmpty ? baseName + suffix : baseName + suffix + "." + ext
            candidate = destinationDirectory.appendingPathComponent(fileName)
            index += 1
        }

        return candidate
    }

    private func firstNonEmptyValue(in metadata: AskInvocationMetadata, keys: [String]) -> String? {
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func boolValue(in metadata: AskInvocationMetadata, keys: [String]) -> Bool? {
        guard let value = firstNonEmptyValue(in: metadata, keys: keys)?.lowercased() else {
            return nil
        }

        switch value {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private func stringListValue(in metadata: AskInvocationMetadata, keys: [String]) -> [String] {
        guard let raw = firstNonEmptyValue(in: metadata, keys: keys) else {
            return []
        }

        return raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct SnapshotCriteria {
    let roots: [URL]
    let extensionFilters: [String]
    let nameContains: String?
    let directChildrenOnly: Bool
    let includeDirectories: Bool
}

private actor AskDesktopOperationStore {
    private var operationsByID: [String: AskStagedOperation] = [:]

    func operation(id: String) -> AskStagedOperation? {
        operationsByID[id]
    }

    func setOperation(_ operation: AskStagedOperation) {
        operationsByID[operation.id] = operation
    }
}
