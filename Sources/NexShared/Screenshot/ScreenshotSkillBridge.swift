import AppKit
import Foundation

enum ScreenshotCapabilityResult {
    case resultEnvelope(SkillResultEnvelope)
    case transientMessage(String, autoHideAfter: TimeInterval)
}

protocol ScreenshotCapabilityFacade {
    func supportedActionIDs(for snapshot: ImageSelectionSnapshot?) -> Set<String>
    func perform(actionID: String, snapshot: ImageSelectionSnapshot, definition: SkillDefinition?) async throws -> ScreenshotCapabilityResult
}

final class ProductScreenshotCapabilityFacade: ScreenshotCapabilityFacade {
    private let ocrService: ScreenshotOCRService
    private let fileManager: FileManager
    private let settings: AppSettings

    init(
        ocrService: ScreenshotOCRService = ScreenshotFeaturePlatformFactory.current().ocrService,
        settings: AppSettings = .shared,
        fileManager: FileManager = .default
    ) {
        self.ocrService = ocrService
        self.settings = settings
        self.fileManager = fileManager
    }

    func supportedActionIDs(for snapshot: ImageSelectionSnapshot?) -> Set<String> {
        guard snapshot != nil else { return [] }
        return ["screenshot_ocr", "screenshot_save"]
    }

    func perform(actionID: String, snapshot: ImageSelectionSnapshot, definition: SkillDefinition?) async throws -> ScreenshotCapabilityResult {
        switch actionID {
        case "screenshot_ocr":
            return .resultEnvelope(try makeOCREnvelope(definition: definition, snapshot: snapshot))
        case "screenshot_save":
            let destination = try persistScreenshot(snapshot)
            return .transientMessage(L10n.format(zhHans: "已保存到 %@", en: "Saved to %@", destination.lastPathComponent), autoHideAfter: 1.8)
        default:
            throw ActionError.network("Unsupported screenshot capability: \(actionID)")
        }
    }

    private func makeOCREnvelope(definition: SkillDefinition?, snapshot: ImageSelectionSnapshot) throws -> SkillResultEnvelope {
        if let recognizedText = snapshot.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recognizedText.isEmpty {
            return ResultSchemaAdapter.resultEnvelope(for: .info(recognizedText), definition: definition)
        }

        guard let image = NSImage(contentsOf: snapshot.imageURL) else {
            throw OCRServiceError.invalidImage
        }

        let blocks = try ocrService.recognizeText(in: image)
        let text = blocks
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.isEmpty ? L10n.text(zhHans: "未识别到文本内容。", en: "No text was recognized.") : text
        return ResultSchemaAdapter.resultEnvelope(for: .info(normalizedText), definition: definition)
    }

    private func persistScreenshot(_ snapshot: ImageSelectionSnapshot) throws -> URL {
        let folderURL = settings.screenshotSaveDirectoryURL
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        var destination = folderURL.appendingPathComponent("NexHub-\(timestamp).png")
        var index = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = folderURL.appendingPathComponent("NexHub-\(timestamp)-\(index).png")
            index += 1
        }

        try fileManager.copyItem(at: snapshot.imageURL, to: destination)
        return destination
    }
}

enum ScreenshotSkillExecutionResult {
    case resultEnvelope(SkillResultEnvelope)
    case transientMessage(String, autoHideAfter: TimeInterval)
}

protocol ScreenshotSkillBridge {
    func supports(definition: SkillDefinition, snapshot: ImageSelectionSnapshot?) -> Bool
    func execute(definition: SkillDefinition, snapshot: ImageSelectionSnapshot) async throws -> ScreenshotSkillExecutionResult
}

final class LegacyScreenshotCapabilityShim: ScreenshotSkillBridge {
    private let capabilityFacade: ScreenshotCapabilityFacade

    init(
        capabilityFacade: ScreenshotCapabilityFacade = ProductScreenshotCapabilityFacade()
    ) {
        self.capabilityFacade = capabilityFacade
    }

    func supports(definition: SkillDefinition, snapshot: ImageSelectionSnapshot?) -> Bool {
        guard definition.stage == .local else { return false }
        return capabilityFacade.supportedActionIDs(for: snapshot).contains(definition.skillID)
    }

    func execute(definition: SkillDefinition, snapshot: ImageSelectionSnapshot) async throws -> ScreenshotSkillExecutionResult {
        switch try await capabilityFacade.perform(actionID: definition.skillID, snapshot: snapshot, definition: definition) {
        case .resultEnvelope(let envelope):
            return .resultEnvelope(envelope)
        case .transientMessage(let message, let autoHideAfter):
            return .transientMessage(message, autoHideAfter: autoHideAfter)
        }
    }
}

@available(*, deprecated, renamed: "LegacyScreenshotCapabilityShim")
typealias LocalScreenshotSkillBridge = LegacyScreenshotCapabilityShim
