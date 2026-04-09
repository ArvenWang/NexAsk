import AppKit
import CoreGraphics
import Foundation

private struct LegacyScreenshotCaptureEngine: ScreenshotCaptureEngine {
    let identifier = "nexhub.capture.legacy"
    let featureSet = ScreenshotFeatureSet([
        .staticCapture,
        .windowSelection,
        .freeformSelection,
        .copyToClipboard,
        .saveToFile,
        .cancelSession
    ])

    func captureImage(
        _ request: ScreenshotCaptureRequest,
        completion: @escaping (ScreenshotCaptureArtifact?) -> Void
    ) {
        ScreenshotCaptureService.captureImage(request.rect, belowWindowID: request.belowWindowID) { image in
            guard let image else {
                completion(nil)
                return
            }
            completion(
                ScreenshotCaptureArtifact(
                    image: image,
                    sourceRect: request.rect,
                    capturedAt: Date()
                )
            )
        }
    }
}

private struct LegacyScreenshotAnnotationEngine: ScreenshotAnnotationEngineProvider {
    let identifier = "nexhub.annotation.legacy"
    let featureSet = ScreenshotFeatureSet([
        .brush,
        .shapes,
        .arrow,
        .text
    ])
}

private struct LegacyScreenshotExportPipeline: ScreenshotExportPipeline {
    let identifier = "nexhub.export.legacy"
    let featureSet = ScreenshotFeatureSet([
        .copyToClipboard,
        .saveToFile,
        .cancelSession
    ])

    func renderSelectionImage(_ request: ScreenshotExportRequest) -> NSImage? {
        let rect = request.selectionRect.integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let image = NSImage(size: rect.size)
        image.lockFocus()
        request.frozenImage.draw(
            in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: request.frozenImage.size),
            from: CGRect(origin: .zero, size: request.frozenImage.size),
            operation: .copy,
            fraction: 1
        )
        ScreenshotAnnotationEngine.drawAnnotations(request.annotations, inSelectionRect: rect)
        image.unlockFocus()
        return image
    }

    func writePNGImage(_ image: NSImage) -> URL? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let filename = "nexhub-shot-\(UUID().uuidString.lowercased()).png"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        do {
            try pngData.write(to: outputURL, options: .atomic)
            return outputURL
        } catch {
            return nil
        }
    }
}

enum ScreenshotFeaturePlatformFactory {
    static func current() -> ScreenshotFeaturePlatform {
        ScreenshotFeaturePlatform(
            captureEngine: LegacyScreenshotCaptureEngine(),
            scrollingEngine: ScrollSnapScrollingCaptureEngine(),
            annotationEngine: LegacyScreenshotAnnotationEngine(),
            ocrService: NativeVisionScreenshotOCRService.shared,
            exportPipeline: LegacyScreenshotExportPipeline(),
            targetFeatureSet: ScreenshotFeatureTarget.nexhubProductSurface
        )
    }
}
