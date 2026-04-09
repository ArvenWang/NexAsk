import AppKit
import Foundation
import NexShared

struct AskFrontmostAppSnapshot: Equatable, Sendable {
    let bundleID: String?
    let appName: String?
}

protocol AskFrontmostAppResolving {
    func frontmostApp() async -> AskFrontmostAppSnapshot?
}

protocol AskSelectionSnapshotReading {
    func currentSelection() async -> SelectionSnapshot?
}

protocol AskBrowserPageReading {
    func currentPage(fromBundleID bundleID: String?) async -> BrowserPageCaptureResult?
}

protocol AskWorkspaceRootResolving {
    func workspaceRoot(for invocation: AskInvocation) async -> String?
}

struct AskSystemFrontmostAppResolver: AskFrontmostAppResolving {
    func frontmostApp() async -> AskFrontmostAppSnapshot? {
        await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return AskFrontmostAppSnapshot(
                bundleID: app?.bundleIdentifier,
                appName: app?.localizedName
            )
        }
    }
}

struct AskSelectionAccessReader: AskSelectionSnapshotReading {
    func currentSelection() async -> SelectionSnapshot? {
        await MainActor.run {
            SelectionAccess.readCurrentSelection(deepSearch: true)
        }
    }
}

struct AskBrowserPageCaptureReader: AskBrowserPageReading {
    private let pageCapture: BrowserPageCaptureProviding

    init(pageCapture: BrowserPageCaptureProviding = BrowserPageCaptureService()) {
        self.pageCapture = pageCapture
    }

    func currentPage(fromBundleID bundleID: String?) async -> BrowserPageCaptureResult? {
        let result = await pageCapture.captureReadableCurrentPage(fromBundleID: bundleID)
        switch result {
        case .success(let page):
            return page
        case .failure:
            return nil
        }
    }
}

struct AskInvocationMetadataWorkspaceResolver: AskWorkspaceRootResolving {
    private static let candidateKeys = [
        "workspace_root",
        "project_root",
        "working_directory",
        "cwd"
    ]

    func workspaceRoot(for invocation: AskInvocation) async -> String? {
        for key in Self.candidateKeys {
            guard let normalized = AskWorkspaceRootSupport.normalizedWorkspaceRoot(invocation.metadata[key]) else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return normalized
                }
                return URL(fileURLWithPath: normalized).deletingLastPathComponent().path
            }
            return normalized
        }

        return nil
    }
}

final class AskLiveContextCaptureHub: AskContextCapturing {
    private let frontmostAppResolver: AskFrontmostAppResolving
    private let selectionReader: AskSelectionSnapshotReading
    private let browserPageReader: AskBrowserPageReading?
    private let workspaceRootResolver: AskWorkspaceRootResolving

    init(
        frontmostAppResolver: AskFrontmostAppResolving = AskSystemFrontmostAppResolver(),
        selectionReader: AskSelectionSnapshotReading = AskSelectionAccessReader(),
        browserPageReader: AskBrowserPageReading? = AskBrowserPageCaptureReader(),
        workspaceRootResolver: AskWorkspaceRootResolving = AskInvocationMetadataWorkspaceResolver()
    ) {
        self.frontmostAppResolver = frontmostAppResolver
        self.selectionReader = selectionReader
        self.browserPageReader = browserPageReader
        self.workspaceRootResolver = workspaceRootResolver
    }

    func captureContext(for invocation: AskInvocation) async -> AskExecutionContext {
        let canInspectForeground = Self.surfaceSupportsForegroundCapture(invocation.surface)
        let frontmostApp = canInspectForeground ? await frontmostAppResolver.frontmostApp() : nil
        let effectiveSourceBundleID = invocation.sourceBundleID ?? frontmostApp?.bundleID
        let effectiveSourceAppName = invocation.sourceAppName ?? frontmostApp?.appName
        let workspaceRoot = await workspaceRootResolver.workspaceRoot(for: invocation)

        var metadata = invocation.metadata
        if let workspaceRoot {
            metadata["workspace_root"] = workspaceRoot
        }
        if let frontmostBundleID = frontmostApp?.bundleID {
            metadata["frontmost_bundle_id"] = frontmostBundleID
        }

        return AskExecutionContext(
            surface: invocation.surface,
            sourceBundleID: effectiveSourceBundleID,
            sourceAppName: effectiveSourceAppName,
            workspaceRootPath: workspaceRoot,
            ambientContext: AskAmbientContext(
                frontmostBundleID: frontmostApp?.bundleID ?? effectiveSourceBundleID,
                currentPageURL: metadata["current_page_url"],
                currentPageTitle: metadata["current_page_title"],
                currentPageTextPreview: metadata["current_page_text_preview"],
                selectedTextPreview: metadata["selection_preview"]
            ),
            timeZoneIdentifier: TimeZone.current.identifier,
            isUserPresent: canInspectForeground && frontmostApp != nil,
            metadata: metadata
        )
    }

    private static func surfaceSupportsForegroundCapture(_ surface: AskInvocationSurface) -> Bool {
        switch surface {
        case .askBox, .globalHotkey, .askWindow, .menuBar, .proactivePopup, .cli, .ide, .notification:
            return true
        case .automation, .inbox, .api, .remoteChannel:
            return false
        }
    }

}
