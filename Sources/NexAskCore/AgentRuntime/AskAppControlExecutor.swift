import AppKit
import Foundation
import NexShared

struct AskAppControlExecutor: AskCapabilityExecuting {
    let supportedCapabilityIDs: [AskCapabilityID] = [
        "app.copy_to_clipboard",
        "app.write_back_to_frontmost_input",
        "app.replace_frontmost_selection",
        "app.focus_application"
    ]

    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        switch request.capability.id {
        case "app.copy_to_clipboard":
            return await copyToClipboard(request: request)
        case "app.write_back_to_frontmost_input":
            return await writeBackToFrontmostInput(request: request)
        case "app.replace_frontmost_selection":
            return await replaceFrontmostSelection(request: request)
        case "app.focus_application":
            return await focusApplication(request: request)
        default:
            return .unsupported(summary: "Unsupported app control capability: \(request.capability.id)")
        }
    }

    private func copyToClipboard(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let text = resolvedText(from: request.arguments) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No text payload was provided for clipboard write.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Copied text to the clipboard.",
            approvalID: nil,
            artifacts: [AskCapabilityArtifact(kind: "clipboard_text", value: String(text.prefix(160)))],
            metadata: ["copied_text_length": String(text.count)]
        )
    }

    private func writeBackToFrontmostInput(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let text = resolvedText(from: request.arguments) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No text payload was provided for foreground write-back.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let sourceBundleID = request.arguments["source_bundle_id"] ?? request.task.context.sourceBundleID
        let result = await withCheckedContinuation { continuation in
            SelectionAccess.writeTextToInput(
                text,
                sourceBundleID: sourceBundleID
            ) { writebackResult in
                continuation.resume(returning: writebackResult)
            }
        }

        switch result {
        case .success(let method, let diagnostics):
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Wrote the content back into the foreground input.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "writeback_text", value: String(text.prefix(160)))],
                metadata: [
                    "method": method,
                    "diagnostics": diagnostics,
                    "source_bundle_id": sourceBundleID ?? ""
                ]
            )
        case .copiedToPasteboard(let reason, let diagnostics):
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Direct write-back failed, and the content was placed on the clipboard instead.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "clipboard_fallback_text", value: String(text.prefix(160)))],
                metadata: [
                    "fallback": "clipboard",
                    "reason": reason,
                    "diagnostics": diagnostics,
                    "source_bundle_id": sourceBundleID ?? ""
                ]
            )
        case .failure(let reason, let diagnostics):
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to write the content back into the foreground input.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "reason": reason,
                    "diagnostics": diagnostics,
                    "source_bundle_id": sourceBundleID ?? ""
                ]
            )
        }
    }

    private func replaceFrontmostSelection(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let text = resolvedText(from: request.arguments) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No replacement text was provided for selection replacement.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let sourceBundleID = request.arguments["source_bundle_id"] ?? request.task.context.sourceBundleID
        let result = await withCheckedContinuation { continuation in
            SelectionAccess.replaceSelectedText(
                with: text,
                sourceBundleID: sourceBundleID,
                replacementTarget: nil,
                selectedText: nil
            ) { replaceResult in
                continuation.resume(returning: replaceResult)
            }
        }

        switch result {
        case .success(let diagnostics):
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Replaced the current selection.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "replacement_text", value: String(text.prefix(160)))],
                metadata: [
                    "diagnostics": diagnostics,
                    "source_bundle_id": sourceBundleID ?? ""
                ]
            )
        case .failure(let reason, let diagnostics):
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to replace the current selection.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "reason": reason,
                    "diagnostics": diagnostics,
                    "source_bundle_id": sourceBundleID ?? ""
                ]
            )
        }
    }

    private func focusApplication(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        let bundleID = request.arguments["bundle_id"]
            ?? request.arguments["source_bundle_id"]
            ?? request.task.context.sourceBundleID
            ?? request.task.context.frontmostBundleID
        let appName = request.arguments["app_name"]

        let activated = await MainActor.run {
            if let bundleID,
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                return app.activate(options: [.activateIgnoringOtherApps])
            }

            if let appName {
                return NSWorkspace.shared.runningApplications
                    .first(where: { $0.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame })?
                    .activate(options: [.activateIgnoringOtherApps]) ?? false
            }

            return false
        }

        guard activated else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to focus the requested application.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "bundle_id": bundleID ?? "",
                    "app_name": appName ?? ""
                ]
            )
        }

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Focused the requested application.",
            approvalID: nil,
            artifacts: [],
            metadata: [
                "bundle_id": bundleID ?? "",
                "app_name": appName ?? ""
            ]
        )
    }

    private func resolvedText(from arguments: AskInvocationMetadata) -> String? {
        let candidates = [
            arguments["text"],
            arguments["content"],
            arguments["replacement"],
            arguments["value"]
        ]
        for candidate in candidates {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else {
                continue
            }
            return candidate
        }
        return nil
    }
}
