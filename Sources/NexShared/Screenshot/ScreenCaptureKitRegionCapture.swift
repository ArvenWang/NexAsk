import AppKit
import Foundation
import ScreenCaptureKit

private final class ScreenCaptureResultBox: @unchecked Sendable {
    let image: NSImage?

    init(image: NSImage?) {
        self.image = image
    }
}

struct ScreenCaptureKitRegionCapture {
    static func captureImage(
        in rect: CGRect,
        excludingOwnApplication: Bool = true,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard rect.width >= 2, rect.height >= 2 else {
            completion(nil)
            return
        }

        Task {
            let result = ScreenCaptureResultBox(
                image: await captureImage(
                    in: rect,
                    excludingOwnApplication: excludingOwnApplication
                )
            )
            await MainActor.run {
                completion(result.image)
            }
        }
    }

    static func captureImage(
        in rect: CGRect,
        excludingOwnApplication: Bool = true
    ) async -> NSImage? {
        if #available(macOS 14.0, *) {
            return await captureImageUsingScreenCaptureKit(
                in: rect,
                excludingOwnApplication: excludingOwnApplication
            )
        }

        return await withCheckedContinuation { continuation in
            ScreenshotCaptureService.captureImage(rect) { image in
                continuation.resume(returning: image)
            }
        }
    }

    @available(macOS 14.0, *)
    private static func captureImageUsingScreenCaptureKit(
        in rect: CGRect,
        excludingOwnApplication: Bool
    ) async -> NSImage? {
        guard let activeScreen = screenContainingPoint(rect.origin),
              let display = await scDisplay(for: activeScreen) else {
            return nil
        }

        let excludedApplications: [SCRunningApplication]
        if excludingOwnApplication, let currentApp = await currentShareableApplication() {
            excludedApplications = [currentApp]
        } else {
            excludedApplications = []
        }

        let adjustedRect = adjustRectForScreen(rect, on: activeScreen)
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let scaleFactor = max(Int(filter.pointPixelScale), 1)
        let config = SCStreamConfiguration()
        config.sourceRect = adjustedRect
        config.width = max(Int(adjustedRect.width) * scaleFactor, 1)
        config.height = max(Int(adjustedRect.height) * scaleFactor, 1)
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: image, size: adjustedRect.size)
        } catch {
            return nil
        }
    }

    private static func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func adjustRectForScreen(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let screenHeight = screen.frame.height + screen.frame.minY
        return CGRect(
            x: rect.origin.x - screen.frame.minX,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func scDisplay(for screen: NSScreen) async -> SCDisplay? {
        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        do {
            let displays = try await SCShareableContent.current.displays
            return displays.first { $0.displayID == screenID }
        } catch {
            return nil
        }
    }

    private static func currentShareableApplication() async -> SCRunningApplication? {
        do {
            let applications = try await SCShareableContent.current.applications
            let currentPID = NSRunningApplication.current.processIdentifier
            return applications.first { $0.processID == currentPID }
        } catch {
            return nil
        }
    }
}
