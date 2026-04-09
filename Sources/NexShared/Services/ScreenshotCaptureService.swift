import AppKit
import Foundation

enum ScreenshotCaptureService {
    static func captureRegionInteractively(completion: @escaping (URL?) -> Void) {
        let filename = "nexhub-shot-\(UUID().uuidString.lowercased()).png"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", outputURL.path]
            do {
                try process.run()
                process.waitUntilExit()
                let ok = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path)
                DispatchQueue.main.async {
                    completion(ok ? outputURL : nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    static func captureRegion(_ rect: CGRect, completion: @escaping (URL?) -> Void) {
        guard rect.width >= 2, rect.height >= 2 else {
            completion(nil)
            return
        }

        let filename = "nexhub-shot-\(UUID().uuidString.lowercased()).png"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        let quartzRect = convertCocoaRectToQuartz(rect)

        DispatchQueue.global(qos: .userInitiated).async {
            let image = captureImageSync(forQuartzRect: quartzRect)
            let ok = image.flatMap { savePNGImage($0, to: outputURL) } ?? false
            DispatchQueue.main.async {
                completion(ok ? outputURL : nil)
            }
        }
    }

    static func captureImage(
        _ rect: CGRect,
        belowWindowID: CGWindowID? = nil,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard rect.width >= 2, rect.height >= 2 else {
            completion(nil)
            return
        }

        let quartzRect = convertCocoaRectToQuartz(rect)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = captureImageSync(forQuartzRect: quartzRect, belowWindowID: belowWindowID)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    static func captureCompositeImage(
        for screens: [NSScreen],
        unionFrame: CGRect,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard !screens.isEmpty,
              unionFrame.width >= 2,
              unionFrame.height >= 2 else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let captures = screens.compactMap { screen -> (CGRect, NSImage)? in
                guard let image = captureImageSync(forCocoaRect: screen.frame) else {
                    return nil
                }
                return (screen.frame, image)
            }

            guard !captures.isEmpty else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let composite = NSImage(size: unionFrame.size)
            composite.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            for (screenFrame, image) in captures {
                let destinationRect = screenFrame.offsetBy(
                    dx: -unionFrame.origin.x,
                    dy: -unionFrame.origin.y
                )
                image.draw(
                    in: destinationRect,
                    from: CGRect(origin: .zero, size: image.size),
                    operation: .copy,
                    fraction: 1
                )
            }
            composite.unlockFocus()

            DispatchQueue.main.async {
                completion(composite)
            }
        }
    }

    private static func convertCocoaRectToQuartz(_ rect: CGRect) -> CGRect {
        let unionFrame = NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partial, frame in
                partial.union(frame)
            }
        guard !unionFrame.isNull else { return rect }
        return CGRect(
            x: rect.minX,
            y: unionFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func captureImageSync(forCocoaRect rect: CGRect, belowWindowID: CGWindowID? = nil) -> NSImage? {
        let quartzRect = convertCocoaRectToQuartz(rect)
        return captureImageSync(forQuartzRect: quartzRect, belowWindowID: belowWindowID)
    }

    private static func captureImageSync(forQuartzRect rect: CGRect, belowWindowID: CGWindowID? = nil) -> NSImage? {
        let listOption: CGWindowListOption = belowWindowID == nil ? .optionOnScreenOnly : .optionOnScreenBelowWindow
        let relativeWindow = belowWindowID ?? kCGNullWindowID
        if let cgImage = CGWindowListCreateImage(
            rect,
            listOption,
            relativeWindow,
            [.bestResolution, .boundsIgnoreFraming]
        ) {
            return NSImage(cgImage: cgImage, size: NSSize(width: rect.width, height: rect.height))
        }
        return captureImageViaScreencapture(from: rect)
    }

    private static func captureImageViaScreencapture(from rect: CGRect) -> NSImage? {
        let filename = "nexhub-shot-\(UUID().uuidString.lowercased()).png"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x",
            "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
            outputURL.path
        ]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return NSImage(contentsOf: outputURL)
        } catch {
            return nil
        }
    }

    private static func savePNGImage(_ image: NSImage, to outputURL: URL) -> Bool {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let data = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: outputURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
