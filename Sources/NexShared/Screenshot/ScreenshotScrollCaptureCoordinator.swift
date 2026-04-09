import AppKit
import Foundation

final class ScreenshotScrollCaptureCoordinator {
    enum State: Equatable {
        case idle
        case capturing(selectionRect: CGRect, startedAt: Date)
        case finishing(selectionRect: CGRect)
    }

    struct Configuration {
        var captureInterval: TimeInterval = 0.25
        var excludesOwnApplication: Bool = true
    }

    private let engine: ScreenshotScrollingCaptureEngine
    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChanged?(state)
        }
    }

    var configuration = Configuration()
    var onStateChanged: ((State) -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    private var captureTimer: Timer?
    private var captureInFlight = false
    init(engine: ScreenshotScrollingCaptureEngine) {
        self.engine = engine
    }

    func startCapture(selectionRect: CGRect, completion: @escaping (Bool) -> Void) {
        cancelPendingWork()
        let normalizedRect = selectionRect.integral

        ScreenCaptureKitRegionCapture.captureImage(
            in: normalizedRect,
            excludingOwnApplication: configuration.excludesOwnApplication
        ) { [weak self] image in
            guard let self else {
                completion(false)
                return
            }
            guard let image else {
                self.state = .idle
                completion(false)
                return
            }

            self.engine.beginSession(with: image)
            self.state = .capturing(selectionRect: normalizedRect, startedAt: Date())
            self.pushPreviewUpdate()
            self.installCaptureTimer(for: normalizedRect)
            completion(true)
        }
    }

    func stopCapture(completion: @escaping (NSImage?) -> Void) {
        guard case let .capturing(selectionRect, _) = state else {
            completion(nil)
            return
        }

        cancelPendingWork()
        state = .finishing(selectionRect: selectionRect)
        engine.finishSession { [weak self] image in
            guard let self else {
                completion(image)
                return
            }
            self.state = .idle
            completion(image)
        }
    }

    func cancel() {
        cancelPendingWork()
        engine.cancelSession()
        state = .idle
    }

    private func installCaptureTimer(for selectionRect: CGRect) {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: configuration.captureInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.captureTick(selectionRect: selectionRect)
        }
    }

    private func captureTick(selectionRect: CGRect) {
        guard case .capturing = state, !captureInFlight else { return }
        captureInFlight = true
        ScreenCaptureKitRegionCapture.captureImage(
            in: selectionRect,
            excludingOwnApplication: configuration.excludesOwnApplication
        ) { [weak self] image in
            guard let self else { return }
            defer { self.captureInFlight = false }
            guard let image else { return }
            self.engine.appendCapture(image)
            self.pushPreviewUpdate()
        }
    }

    private func cancelPendingWork() {
        captureTimer?.invalidate()
        captureTimer = nil
        captureInFlight = false
    }

    private func pushPreviewUpdate() {
        engine.snapshotPreview { [weak self] image in
            guard let self, let image else { return }
            self.onPreviewUpdated?(image)
        }
    }
}
