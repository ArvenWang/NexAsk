import AppKit
import CoreGraphics
import Foundation

enum ScreenshotCapability: String, CaseIterable, Hashable {
    case staticCapture
    case windowSelection
    case freeformSelection
    case scrollingCapture
    case brush
    case shapes
    case arrow
    case text
    case ocr
    case watermark
    case redaction
    case copyToClipboard
    case saveToFile
    case cancelSession
    case undoRedo
}

struct ScreenshotFeatureSet: Equatable {
    private(set) var capabilities: Set<ScreenshotCapability>

    init(_ capabilities: Set<ScreenshotCapability> = []) {
        self.capabilities = capabilities
    }

    func supports(_ capability: ScreenshotCapability) -> Bool {
        capabilities.contains(capability)
    }

    func union(_ other: ScreenshotFeatureSet) -> ScreenshotFeatureSet {
        ScreenshotFeatureSet(capabilities.union(other.capabilities))
    }
}

struct ScreenshotCaptureArtifact {
    let image: NSImage
    let sourceRect: CGRect
    let capturedAt: Date
}

struct ScreenshotCaptureRequest {
    let rect: CGRect
    let belowWindowID: CGWindowID?

    init(rect: CGRect, belowWindowID: CGWindowID? = nil) {
        self.rect = rect
        self.belowWindowID = belowWindowID
    }
}

struct ScrollingScreenshotRequest {
    let appBundleID: String?
    let startingRect: CGRect
}

struct OCRTextBlock: Equatable {
    let text: String
    let bounds: CGRect
}

struct ScreenshotExportRequest {
    let frozenImage: NSImage
    let selectionRect: CGRect
    let annotations: [ScreenshotOverlayAnnotation]
}

protocol ScreenshotCaptureEngine {
    var identifier: String { get }
    var featureSet: ScreenshotFeatureSet { get }

    func captureImage(
        _ request: ScreenshotCaptureRequest,
        completion: @escaping (ScreenshotCaptureArtifact?) -> Void
    )
}

protocol ScreenshotScrollingCaptureEngine {
    var identifier: String { get }
    var featureSet: ScreenshotFeatureSet { get }

    func beginSession(with initialImage: NSImage)
    func appendCapture(_ image: NSImage)
    func snapshotPreview(completion: @escaping (NSImage?) -> Void)
    func cancelSession()
    func finishSession(completion: @escaping (NSImage?) -> Void)
}

protocol ScreenshotAnnotationEngineProvider {
    var identifier: String { get }
    var featureSet: ScreenshotFeatureSet { get }
}

protocol ScreenshotOCRService {
    var identifier: String { get }
    var featureSet: ScreenshotFeatureSet { get }

    func recognizeText(in image: NSImage) throws -> [OCRTextBlock]
}

protocol ScreenshotExportPipeline {
    var identifier: String { get }
    var featureSet: ScreenshotFeatureSet { get }

    func renderSelectionImage(_ request: ScreenshotExportRequest) -> NSImage?
    func writePNGImage(_ image: NSImage) -> URL?
}

struct ScreenshotFeaturePlatform {
    let captureEngine: ScreenshotCaptureEngine
    let scrollingEngine: ScreenshotScrollingCaptureEngine
    let annotationEngine: ScreenshotAnnotationEngineProvider
    let ocrService: ScreenshotOCRService
    let exportPipeline: ScreenshotExportPipeline
    let targetFeatureSet: ScreenshotFeatureSet

    var currentFeatureSet: ScreenshotFeatureSet {
        captureEngine.featureSet
            .union(scrollingEngine.featureSet)
            .union(annotationEngine.featureSet)
            .union(ocrService.featureSet)
            .union(exportPipeline.featureSet)
    }

    var missingTargetCapabilities: [ScreenshotCapability] {
        ScreenshotCapability.allCases.filter { targetFeatureSet.supports($0) && !currentFeatureSet.supports($0) }
    }
}

enum ScreenshotFeatureTarget {
    static let nexhubProductSurface = ScreenshotFeatureSet([
        .staticCapture,
        .windowSelection,
        .freeformSelection,
        .scrollingCapture,
        .brush,
        .shapes,
        .arrow,
        .text,
        .ocr,
        .watermark,
        .redaction,
        .copyToClipboard,
        .saveToFile,
        .cancelSession,
        .undoRedo
    ])
}
