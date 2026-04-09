import AppKit
import Foundation
import Vision

final class ScrollSnapScrollingCaptureEngine: ScreenshotScrollingCaptureEngine {
    private enum GrowthDirection {
        case upward
        case downward
    }

    let identifier = "scrollsnap.stitching.engine"
    let featureSet = ScreenshotFeatureSet([.scrollingCapture])
    private let minimumAcceptedOffset: CGFloat = 10
    private let maximumOffsetRatio: CGFloat = 0.9

    private var runningStitchedImage: NSImage?
    private var previousImage: NSImage?
    private var previousImageSignature: Data?
    private var growthDirection: GrowthDirection?
    private let stitchingQueue = DispatchQueue(label: "com.nexhub.screenshot.stitching", qos: .userInitiated)

    func beginSession(with initialImage: NSImage) {
        stitchingQueue.async {
            self.runningStitchedImage = initialImage
            self.previousImage = initialImage
            self.previousImageSignature = initialImage.tiffRepresentation
            self.growthDirection = nil
        }
    }

    func appendCapture(_ image: NSImage) {
        stitchingQueue.async {
            guard let baseStitchedImage = self.runningStitchedImage,
                  let previousImage = self.previousImage else {
                self.runningStitchedImage = image
                self.previousImage = image
                self.previousImageSignature = image.tiffRepresentation
                return
            }

            let currentSignature = image.tiffRepresentation
            if let currentSignature, currentSignature == self.previousImageSignature {
                return
            }

            guard let offsetInPoints = self.calculateOffset(from: image, to: previousImage) else {
                self.previousImage = image
                self.previousImageSignature = currentSignature
                return
            }

            let magnitude = abs(offsetInPoints)
            let maxAcceptedOffset = image.size.height * self.maximumOffsetRatio
            guard magnitude >= self.minimumAcceptedOffset,
                  magnitude <= maxAcceptedOffset else {
                self.previousImage = image
                self.previousImageSignature = currentSignature
                return
            }

            let inferredDirection: GrowthDirection = offsetInPoints > 0 ? .downward : .upward
            if let growthDirection = self.growthDirection, growthDirection != inferredDirection {
                self.previousImage = image
                self.previousImageSignature = currentSignature
                return
            }
            self.growthDirection = inferredDirection

            let newStitchedImage: NSImage?
            switch inferredDirection {
            case .downward:
                newStitchedImage = self.appendToBottom(
                    baseImage: baseStitchedImage,
                    newImage: image,
                    offset: magnitude
                )
            case .upward:
                newStitchedImage = self.prependToTop(
                    baseImage: baseStitchedImage,
                    newImage: image,
                    offset: magnitude
                )
            }

            guard let newStitchedImage else {
                self.previousImage = image
                self.previousImageSignature = currentSignature
                return
            }

            self.runningStitchedImage = newStitchedImage
            self.previousImage = image
            self.previousImageSignature = currentSignature
        }
    }

    func snapshotPreview(completion: @escaping (NSImage?) -> Void) {
        stitchingQueue.async {
            let preview = self.runningStitchedImage
            DispatchQueue.main.async {
                completion(preview)
            }
        }
    }

    func cancelSession() {
        stitchingQueue.async {
            self.runningStitchedImage = nil
            self.previousImage = nil
            self.previousImageSignature = nil
            self.growthDirection = nil
        }
    }

    func finishSession(completion: @escaping (NSImage?) -> Void) {
        stitchingQueue.async {
            let finalImage = self.runningStitchedImage
            self.runningStitchedImage = nil
            self.previousImage = nil
            self.previousImageSignature = nil
            self.growthDirection = nil
            DispatchQueue.main.async {
                completion(finalImage)
            }
        }
    }

    private func calculateOffset(from currentImage: NSImage, to previousImage: NSImage) -> CGFloat? {
        guard let currentCG = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let previousCG = previousImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        guard let verticalOffsetInPixels = findVerticalOffset(from: currentCG, to: previousCG) else {
            return nil
        }

        guard currentImage.size.height > 0 else { return nil }
        let scale = CGFloat(currentCG.height) / currentImage.size.height
        return verticalOffsetInPixels / (scale > 0 ? scale : 1.0)
    }

    private func findVerticalOffset(from image1: CGImage, to image2: CGImage) -> CGFloat? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image2)
        let handler = VNImageRequestHandler(cgImage: image1, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }

        return observation.alignmentTransform.ty
    }

    private func appendToBottom(baseImage: NSImage, newImage: NSImage, offset: CGFloat) -> NSImage? {
        let baseSize = baseImage.size
        let newSize = newImage.size
        let totalHeight = baseSize.height + offset
        let outputSize = NSSize(width: baseSize.width, height: totalHeight)

        let outputImage = NSImage(size: outputSize)
        outputImage.lockFocus()

        let baseRect = CGRect(
            x: 0,
            y: totalHeight - baseSize.height,
            width: baseSize.width,
            height: baseSize.height
        )
        baseImage.draw(in: baseRect)

        let newRect = CGRect(x: 0, y: 0, width: newSize.width, height: newSize.height)
        newImage.draw(in: newRect)

        outputImage.unlockFocus()
        return outputImage
    }

    private func prependToTop(baseImage: NSImage, newImage: NSImage, offset: CGFloat) -> NSImage? {
        let baseSize = baseImage.size
        let newSize = newImage.size
        let totalHeight = baseSize.height + offset
        let outputSize = NSSize(width: baseSize.width, height: totalHeight)

        let outputImage = NSImage(size: outputSize)
        outputImage.lockFocus()

        let baseRect = CGRect(
            x: 0,
            y: 0,
            width: baseSize.width,
            height: baseSize.height
        )
        baseImage.draw(in: baseRect)

        // Mirror ScrollSnap's downward compositing math for true upward growth:
        // keep the stitched result anchored at the bottom and place the latest
        // frame so its non-overlapping top slice extends the canvas upward.
        let newRect = CGRect(
            x: 0,
            y: totalHeight - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        newImage.draw(in: newRect)

        outputImage.unlockFocus()
        return outputImage
    }

}
