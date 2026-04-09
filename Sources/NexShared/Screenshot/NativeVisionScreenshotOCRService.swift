import AppKit
import Foundation
import Vision

final class NativeVisionScreenshotOCRService: ScreenshotOCRService {
    static let shared = NativeVisionScreenshotOCRService()

    let identifier = "nexhub.ocr.vision"
    let featureSet = ScreenshotFeatureSet([.ocr])

    private init() {}

    func recognizeText(in image: NSImage) throws -> [OCRTextBlock] {
        guard let cgImage = Self.cgImage(from: image) else {
            throw OCRServiceError.invalidImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return OCRTextBlock(text: text, bounds: observation.boundingBox)
            }
            .sorted(by: Self.sortBlocks)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        if let direct = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return direct
        }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.cgImage
    }

    private static func sortBlocks(lhs: OCRTextBlock, rhs: OCRTextBlock) -> Bool {
        let lhsTop = lhs.bounds.maxY
        let rhsTop = rhs.bounds.maxY
        if abs(lhsTop - rhsTop) > 0.04 {
            return lhsTop > rhsTop
        }
        return lhs.bounds.minX < rhs.bounds.minX
    }
}

enum OCRServiceError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return L10n.text(zhHans: "无法读取当前截图内容。", en: "Unable to read the current screenshot.")
        }
    }
}
