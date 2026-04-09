import Foundation

package enum AskOperationKind: String, Equatable {
    case move
}

package enum AskOperationStatus: String, Equatable {
    case staged
    case awaitingApproval
    case committed
    case cancelled
    case failed
}

package struct AskPathRecord: Equatable {
    package let path: String
    package let name: String
    package let parentPath: String
    package let isDirectory: Bool
    package let sizeBytes: Int64?
    package let modifiedAt: Date?

    package init(
        path: String,
        name: String,
        parentPath: String,
        isDirectory: Bool,
        sizeBytes: Int64?,
        modifiedAt: Date?
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

package struct AskDirectorySnapshot: Equatable {
    package let id: String
    package let rootDirectories: [String]
    package let directChildrenOnly: Bool
    package let includeDirectories: Bool
    package let extensionFilters: [String]
    package let nameContains: String?
    package let items: [AskPathRecord]
    package let createdAt: Date

    package init(
        id: String,
        rootDirectories: [String],
        directChildrenOnly: Bool,
        includeDirectories: Bool,
        extensionFilters: [String],
        nameContains: String?,
        items: [AskPathRecord],
        createdAt: Date
    ) {
        self.id = id
        self.rootDirectories = rootDirectories
        self.directChildrenOnly = directChildrenOnly
        self.includeDirectories = includeDirectories
        self.extensionFilters = extensionFilters
        self.nameContains = nameContains
        self.items = items
        self.createdAt = createdAt
    }
}

package struct AskPathSelection: Equatable {
    package let id: String
    package let snapshotID: String
    package let paths: [String]
    package let createdAt: Date

    package init(id: String, snapshotID: String, paths: [String], createdAt: Date) {
        self.id = id
        self.snapshotID = snapshotID
        self.paths = paths
        self.createdAt = createdAt
    }
}

package struct AskStagedOperationCollision: Equatable {
    package let sourcePath: String
    package let destinationPath: String

    package init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

package struct AskStagedOperation: Equatable {
    package let id: String
    package let sessionID: String
    package let kind: AskOperationKind
    package let sourceSnapshotID: String?
    package let selectionID: String?
    package let sourcePaths: [String]
    package let destinationDirectoryPath: String
    package let createDestinationIfNeeded: Bool
    package let affectedItemCount: Int
    package let previewPaths: [String]
    package let collisions: [AskStagedOperationCollision]
    package let skippedPaths: [String]
    package var status: AskOperationStatus
    package let createdAt: Date

    package init(
        id: String,
        sessionID: String,
        kind: AskOperationKind,
        sourceSnapshotID: String?,
        selectionID: String?,
        sourcePaths: [String],
        destinationDirectoryPath: String,
        createDestinationIfNeeded: Bool,
        affectedItemCount: Int,
        previewPaths: [String],
        collisions: [AskStagedOperationCollision],
        skippedPaths: [String],
        status: AskOperationStatus,
        createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.sourceSnapshotID = sourceSnapshotID
        self.selectionID = selectionID
        self.sourcePaths = sourcePaths
        self.destinationDirectoryPath = destinationDirectoryPath
        self.createDestinationIfNeeded = createDestinationIfNeeded
        self.affectedItemCount = affectedItemCount
        self.previewPaths = previewPaths
        self.collisions = collisions
        self.skippedPaths = skippedPaths
        self.status = status
        self.createdAt = createdAt
    }

    package var matchedFilePaths: [String] {
        sourcePaths
    }
}
