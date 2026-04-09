import Foundation

package enum AskWorkspaceRootSupport {
    package static let kernelMetadataKeys: Set<String> = [
        "workspace_root",
        "active_task_workspace_root",
        "interactive_task_scope_root",
        "task_workspace_root",
        "assistant_delivery_workspace_root"
    ]

    package static func normalizedWorkspaceRoot(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.path
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    package static func sanitizedKernelMetadata(_ metadata: [String: String]) -> [String: String] {
        var sanitized = metadata
        for key in kernelMetadataKeys {
            if let normalized = normalizedWorkspaceRoot(sanitized[key]) {
                sanitized[key] = normalized
            } else {
                sanitized.removeValue(forKey: key)
            }
        }
        return sanitized
    }
}
