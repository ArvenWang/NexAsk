import Foundation

protocol ActivationArtifactProtocol {
    var activationContext: ActivationContext { get }
    var sourceInteractionContext: SourceInteractionContext { get }
    var metadata: ArtifactMetadata { get }
    var displayText: String { get }
}

extension TextSelectionArtifact: ActivationArtifactProtocol {}
extension FileSelectionArtifact: ActivationArtifactProtocol {}
extension ImageSelectionArtifact: ActivationArtifactProtocol {}

extension ActivationArtifact: ActivationArtifactProtocol {
    var metadata: ArtifactMetadata {
        switch self {
        case .text(let artifact):
            return artifact.metadata
        case .file(let artifact):
            return artifact.metadata
        case .image(let artifact):
            return artifact.metadata
        }
    }

    var displayText: String {
        switch self {
        case .text(let artifact):
            return artifact.displayText
        case .file(let artifact):
            return artifact.displayText
        case .image(let artifact):
            return artifact.displayText
        }
    }
}
