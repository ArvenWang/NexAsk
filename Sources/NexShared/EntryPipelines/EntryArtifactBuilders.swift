import Foundation

struct TextArtifactBuilder {
    func build(from snapshot: SelectionSnapshot) -> TextSelectionArtifact {
        TextSelectionArtifact(snapshot: snapshot)
    }
}

struct FileArtifactBuilder {
    func build(from snapshot: FileSelectionSnapshot) -> FileSelectionArtifact {
        FileSelectionArtifact(snapshot: snapshot)
    }
}

struct ImageArtifactBuilder {
    func build(from snapshot: ImageSelectionSnapshot) -> ImageSelectionArtifact {
        ImageSelectionArtifact(snapshot: snapshot)
    }
}
