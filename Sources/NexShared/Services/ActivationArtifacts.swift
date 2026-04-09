import AppKit
import Foundation

struct ArtifactMetadata: Equatable {
    let source: ActivationSource
    let contentType: ActivationContentType
    let bundleID: String?
    let appName: String?
    let capturedAt: Date
    let sourceInteractionContext: SourceInteractionContext
    let artifactDetails: ActivationArtifactDetails

    init(
        source: ActivationSource,
        contentType: ActivationContentType,
        bundleID: String?,
        appName: String?,
        capturedAt: Date = Date(),
        sourceInteractionContext: SourceInteractionContext = .empty,
        artifactDetails: ActivationArtifactDetails = .init()
    ) {
        self.source = source
        self.contentType = contentType
        self.bundleID = bundleID
        self.appName = appName
        self.capturedAt = capturedAt
        self.sourceInteractionContext = sourceInteractionContext
        self.artifactDetails = artifactDetails
    }
}

struct TextSelectionArtifact: Equatable {
    let text: String
    let selectionLength: Int
    let anchorPoint: CGPoint
    let metadata: ArtifactMetadata
    let sourceInteractionContext: SourceInteractionContext

    init(snapshot: SelectionSnapshot) {
        let sourceInteractionContext = SourceAppPolicy.interactionContext(
            source: .selectedText,
            bundleID: snapshot.sourceBundleID,
            replacementTarget: snapshot.replacementTarget,
            selectedText: snapshot.text
        )
        self.text = snapshot.text
        self.selectionLength = snapshot.text.count
        self.anchorPoint = snapshot.anchorPoint
        self.sourceInteractionContext = sourceInteractionContext
        self.metadata = ArtifactMetadata(
            source: .selectedText,
            contentType: .text,
            bundleID: snapshot.sourceBundleID,
            appName: ArtifactMetadata.resolveAppName(bundleID: snapshot.sourceBundleID),
            sourceInteractionContext: sourceInteractionContext,
            artifactDetails: ActivationArtifactDetails(
                selectionLength: snapshot.text.count
            )
        )
    }

    var activationContext: ActivationContext {
        ActivationContext(
            id: ActivationArtifact.makeContextID(),
            source: metadata.source,
            contentType: metadata.contentType,
            raw: ActivationContextRaw(
                text: text,
                filePaths: nil,
                selectionLength: selectionLength
            ),
            metadata: metadata.activationContextMetadata
        )
    }

    var displayText: String {
        text
    }
}

struct FileSelectionArtifact: Equatable {
    let fileURLs: [URL]
    let displayNames: [String]
    let directoryCount: Int
    let totalByteCount: Int64
    let anchorPoint: CGPoint
    let metadata: ArtifactMetadata
    let sourceInteractionContext: SourceInteractionContext

    init(snapshot: FileSelectionSnapshot) {
        let sourceInteractionContext = SourceAppPolicy.interactionContext(
            source: .fileSelection,
            bundleID: snapshot.sourceBundleID,
            replacementTarget: nil,
            selectedText: nil
        )
        self.fileURLs = snapshot.fileURLs
        self.displayNames = snapshot.fileURLs.map(\.lastPathComponent)
        self.directoryCount = snapshot.fileURLs.filter(\.hasDirectoryPath).count
        self.totalByteCount = snapshot.fileURLs.reduce(into: 0) { partialResult, fileURL in
            partialResult += ArtifactMetadata.fileByteCount(at: fileURL)
        }
        self.anchorPoint = snapshot.anchorPoint
        self.sourceInteractionContext = sourceInteractionContext
        self.metadata = ArtifactMetadata(
            source: .fileSelection,
            contentType: .file,
            bundleID: snapshot.sourceBundleID,
            appName: ArtifactMetadata.resolveAppName(bundleID: snapshot.sourceBundleID),
            sourceInteractionContext: sourceInteractionContext,
            artifactDetails: ActivationArtifactDetails(
                fileCount: snapshot.fileURLs.count,
                directoryCount: directoryCount,
                totalByteCount: totalByteCount
            )
        )
    }

    var selectionCount: Int {
        fileURLs.count
    }

    var displayText: String {
        displayNames.joined(separator: "\n")
    }

    var activationContext: ActivationContext {
        ActivationContext(
            id: ActivationArtifact.makeContextID(),
            source: metadata.source,
            contentType: metadata.contentType,
            raw: ActivationContextRaw(
                text: displayText,
                filePaths: fileURLs.map(\.path),
                fileCount: selectionCount,
                directoryCount: directoryCount,
                totalByteCount: totalByteCount
            ),
            metadata: metadata.activationContextMetadata
        )
    }
}

struct ImageSelectionArtifact: Equatable {
    let imageURL: URL
    let selectionRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let anchorPoint: CGPoint
    let contentHints: ScreenshotContentHints?
    let metadata: ArtifactMetadata
    let sourceInteractionContext: SourceInteractionContext

    init(snapshot: ImageSelectionSnapshot) {
        let sourceInteractionContext = SourceAppPolicy.interactionContext(
            source: .screenshotRegion,
            bundleID: snapshot.sourceBundleID,
            replacementTarget: nil,
            selectedText: nil
        )
        self.imageURL = snapshot.imageURL
        self.selectionRect = snapshot.selectionRect
        self.pixelWidth = snapshot.pixelWidth
        self.pixelHeight = snapshot.pixelHeight
        self.anchorPoint = snapshot.anchorPoint
        self.contentHints = snapshot.contentHints
        self.sourceInteractionContext = sourceInteractionContext
        self.metadata = ArtifactMetadata(
            source: .screenshotRegion,
            contentType: .image,
            bundleID: snapshot.sourceBundleID,
            appName: ArtifactMetadata.resolveAppName(bundleID: snapshot.sourceBundleID),
            sourceInteractionContext: sourceInteractionContext,
            artifactDetails: ActivationArtifactDetails(
                pixelWidth: snapshot.pixelWidth,
                pixelHeight: snapshot.pixelHeight,
                recognizedTextLength: snapshot.contentHints?.recognizedTextLength,
                ocrLineCount: snapshot.contentHints?.lineCount,
                hasAnnotations: false,
                isScrollingCapture: false
            )
        )
    }

    var displayText: String {
        imageURL.lastPathComponent
    }

    var activationContext: ActivationContext {
        ActivationContext(
            id: ActivationArtifact.makeContextID(),
            source: metadata.source,
            contentType: metadata.contentType,
            raw: ActivationContextRaw(
                text: contentHints?.recognizedText,
                filePaths: [imageURL.path],
                fileCount: 1,
                totalByteCount: ArtifactMetadata.fileByteCount(at: imageURL),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                recognizedTextLength: contentHints?.recognizedTextLength,
                ocrLineCount: contentHints?.lineCount,
                hasAnnotations: metadata.artifactDetails.hasAnnotations,
                isScrollingCapture: metadata.artifactDetails.isScrollingCapture
            ),
            metadata: metadata.activationContextMetadata
        )
    }
}

enum ActivationArtifact: Equatable {
    case text(TextSelectionArtifact)
    case file(FileSelectionArtifact)
    case image(ImageSelectionArtifact)

    var activationContext: ActivationContext {
        switch self {
        case .text(let artifact):
            return artifact.activationContext
        case .file(let artifact):
            return artifact.activationContext
        case .image(let artifact):
            return artifact.activationContext
        }
    }

    var sourceInteractionContext: SourceInteractionContext {
        switch self {
        case .text(let artifact):
            return artifact.sourceInteractionContext
        case .file(let artifact):
            return artifact.sourceInteractionContext
        case .image(let artifact):
            return artifact.sourceInteractionContext
        }
    }

    fileprivate static func makeContextID() -> String {
        "ctx_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private extension ArtifactMetadata {
    static func resolveAppName(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName
    }

    var activationContextMetadata: ActivationContextMetadata {
        ActivationContextMetadata(
            bundleID: bundleID,
            appName: appName,
            timestamp: ArtifactTimestampFormatter.shared.string(from: capturedAt),
            artifact: artifactDetails
        )
    }

    static func fileByteCount(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isDirectory == true {
            return 0
        }
        if let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            return Int64(allocated)
        }
        if let fileSize = values?.fileSize {
            return Int64(fileSize)
        }
        return 0
    }
}

private enum ArtifactTimestampFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}
