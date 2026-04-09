import AppKit
import Foundation

package struct ScreenshotContentHints: Equatable {
    package let recognizedText: String?
    package let lineCount: Int
    package let recognizedTextLength: Int

    package static let empty = ScreenshotContentHints(
        recognizedText: nil,
        lineCount: 0,
        recognizedTextLength: 0
    )

    package var hasMeaningfulText: Bool {
        recognizedTextLength >= 8 || lineCount >= 2
    }

    package func previewText(limit: Int = 80) -> String? {
        guard let recognizedText else { return nil }
        let normalized = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }
}

final class ScreenshotContentAnalyzer {
    static let shared = ScreenshotContentAnalyzer()

    private let ocrService: ScreenshotOCRService
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: [String: ScreenshotContentHints] = [:]

    init(
        ocrService: ScreenshotOCRService = ScreenshotFeaturePlatformFactory.current().ocrService,
        fileManager: FileManager = .default
    ) {
        self.ocrService = ocrService
        self.fileManager = fileManager
    }

    func analyze(imageURL: URL, pixelWidth: Int, pixelHeight: Int) -> ScreenshotContentHints {
        guard fileManager.fileExists(atPath: imageURL.path),
              let cacheKey = cacheKey(for: imageURL, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return .empty
        }

        if let cached = cachedHints(for: cacheKey) {
            return cached
        }

        guard let image = NSImage(contentsOf: imageURL) else {
            store(.empty, for: cacheKey)
            return .empty
        }

        let hints: ScreenshotContentHints
        do {
            let blocks = try ocrService.recognizeText(in: image)
            let text = blocks
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hints = ScreenshotContentHints(
                recognizedText: text.isEmpty ? nil : text,
                lineCount: blocks.count,
                recognizedTextLength: text.count
            )
        } catch {
            hints = .empty
        }

        store(hints, for: cacheKey)
        return hints
    }

    private func cachedHints(for key: String) -> ScreenshotContentHints? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ hints: ScreenshotContentHints, for key: String) {
        lock.lock()
        cache[key] = hints
        lock.unlock()
    }

    private func cacheKey(for imageURL: URL, pixelWidth: Int, pixelHeight: Int) -> String? {
        let values = try? imageURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ])
        let timestamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        return [
            imageURL.path,
            String(format: "%.6f", timestamp),
            "\(fileSize)",
            "\(pixelWidth)x\(pixelHeight)"
        ].joined(separator: "|")
    }
}
