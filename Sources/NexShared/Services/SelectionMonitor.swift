import AppKit
import Foundation

protocol SelectionMonitorDelegate: AnyObject {
    func selectionMonitor(_ monitor: SelectionMonitor, didUpdate snapshot: SelectionSnapshot)
    func selectionMonitorDidClearSelection(_ monitor: SelectionMonitor)
}

final class SelectionMonitor {
    private struct CaptureAttempt {
        let delay: TimeInterval
        let deepSearch: Bool
    }

    private enum CaptureProfile {
        case standard
        case wechat

        var attempts: [CaptureAttempt] {
            switch self {
            case .standard:
                return [
                    .init(delay: 0.008, deepSearch: false),
                    .init(delay: 0.028, deepSearch: false),
                    .init(delay: 0.065, deepSearch: true),
                    .init(delay: 0.125, deepSearch: true),
                ]
            case .wechat:
                return [
                    .init(delay: 0.006, deepSearch: false),
                    .init(delay: 0.020, deepSearch: false),
                    .init(delay: 0.050, deepSearch: true),
                    .init(delay: 0.095, deepSearch: true),
                ]
            }
        }

        var clipboardBridgeDelay: TimeInterval? {
            switch self {
            case .standard:
                return nil
            case .wechat:
                return 0.035
            }
        }
    }

    weak var delegate: SelectionMonitorDelegate?

    private let settings: AppSettings
    private let diagnosticsLogger = DiagnosticsLogger.shared
    private var isRunning = false
    private var timer: DispatchSourceTimer?
    private var lastSelectionHash: Int?
    private var lastEmissionAt: Date = .distantPast
    private var lastIntentAt: Date = .distantPast
    private var pendingWorkItems: [DispatchWorkItem] = []
    private var activeIntentID: UUID?
    private var activeIntentDelivered = false
    private var lastDragCaptureAt: Date = .distantPast

    private var compatibilityBridgeBundles: Set<String> {
        Set(settings.compatibilityBridgeBundleIDs)
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func start() {
        stop()
        isRunning = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(140), repeating: .milliseconds(240))
        timer.setEventHandler { [weak self] in
            self?.pollFallbackTick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        cancelPendingCaptures()
        if lastSelectionHash != nil {
            lastSelectionHash = nil
            diagnosticsLogger.log("selection.clear", "source=monitor")
            delegate?.selectionMonitorDidClearSelection(self)
        }
    }

    func captureFromMouseSelectionIntent(strong: Bool) {
        guard isRunning else { return }
        guard Date().timeIntervalSince(lastIntentAt) > 0.03 else { return }
        lastIntentAt = Date()
        let profile = captureProfileForFrontmostApp(strong: strong)
        if strong {
            scheduleAccessibilityCapture(profile: profile)
        } else {
            scheduleAccessibilityCapture(profile: .standard)
        }
    }

    func captureFromMouseDragIntent() {
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDragCaptureAt) > 0.025 else { return }
        lastDragCaptureAt = now
        guard let snapshot = SelectionAccess.readCurrentSelection(deepSearch: false) else { return }
        emitIfChanged(snapshot)
    }

    func captureFromKeyboardSelectionIntent() {
        guard isRunning else { return }
        lastIntentAt = Date()
        scheduleAccessibilityCapture(profile: captureProfileForFrontmostApp(strong: true))
    }

    func runtimeDiagnosticSummary(for snapshot: SelectionSnapshot?) -> String {
        let frontmostBundleID = SelectionAccess.frontmostBundleID() ?? "unknown"
        let bridgeEnabled = compatibilityBridgeBundles.contains(frontmostBundleID)
        let strongIntentProfile = bridgeEnabled ? CaptureProfile.wechat : .standard
        let urlWouldBeFiltered = snapshot.map { $0.origin == .accessibility && TextURLDetector.isStandaloneURL($0.text) } ?? false

        return [
            "frontmostApp=\(frontmostBundleID)",
            "strongIntentProfile=\(profileName(strongIntentProfile))",
            "compatibilityBridge=\(bridgeEnabled ? "enabled" : "disabled")",
            "urlFilterWouldBlock=\(urlWouldBeFiltered ? "yes" : "no")"
        ].joined(separator: "\n")
    }

    private func captureProfileForFrontmostApp(strong: Bool) -> CaptureProfile {
        guard strong,
              let bundleID = SelectionAccess.frontmostBundleID(),
              compatibilityBridgeBundles.contains(bundleID) else {
            return .standard
        }
        return .wechat
    }

    private func scheduleAccessibilityCapture(profile: CaptureProfile) {
        cancelPendingCaptures()
        let intentID = UUID()
        activeIntentID = intentID
        activeIntentDelivered = false

        for attempt in profile.attempts {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                guard self.activeIntentID == intentID else { return }
                if let snapshot = SelectionAccess.readCurrentSelection(deepSearch: attempt.deepSearch) {
                    if self.activeIntentDelivered {
                        self.emitIfChanged(snapshot)
                    } else {
                        self.activeIntentDelivered = true
                        self.emitIfChanged(snapshot, force: true)
                    }
                }
            }
            pendingWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + attempt.delay, execute: work)
        }

        guard let clipboardDelay = profile.clipboardBridgeDelay else { return }
        let fallbackWork = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            guard self.activeIntentID == intentID, !self.activeIntentDelivered else { return }
            guard let bundleID = SelectionAccess.frontmostBundleID(),
                  self.compatibilityBridgeBundles.contains(bundleID) else {
                return
            }

            SelectionAccess.captureSelectionBySyntheticCopy { [weak self] snapshot in
                guard let self, self.isRunning else { return }
                guard self.activeIntentID == intentID, !self.activeIntentDelivered else { return }
                guard let snapshot else { return }
                self.activeIntentDelivered = true
                self.emitIfChanged(snapshot, force: true)
            }
        }
        pendingWorkItems.append(fallbackWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardDelay, execute: fallbackWork)
    }

    private func pollFallbackTick() {
        guard isRunning else { return }
        if let snapshot = SelectionAccess.readCurrentSelection(deepSearch: false) {
            let hasRecentIntent = Date().timeIntervalSince(lastIntentAt) <= 0.9
            if hasRecentIntent {
                emitIfChanged(snapshot)
                return
            }
            if snapshot.origin == .accessibility, TextURLDetector.isStandaloneURL(snapshot.text) {
                return
            }
            return
        }

        if lastSelectionHash != nil, Date().timeIntervalSince(lastEmissionAt) > 1.2 {
            lastSelectionHash = nil
            delegate?.selectionMonitorDidClearSelection(self)
        }
    }

    private func cancelPendingCaptures() {
        for work in pendingWorkItems {
            work.cancel()
        }
        pendingWorkItems.removeAll()
    }

    private func emitIfChanged(_ snapshot: SelectionSnapshot, force: Bool = false) {
        let hashValue = hash(snapshot: snapshot)
        if !force, hashValue == lastSelectionHash {
            return
        }

        lastSelectionHash = hashValue
        lastEmissionAt = Date()
        diagnosticsLogger.log(
            "selection.capture",
            "force=\(force) origin=\(snapshot.origin) bundle=\(snapshot.sourceBundleID ?? "unknown") length=\(snapshot.text.count)"
        )
        delegate?.selectionMonitor(self, didUpdate: snapshot)
    }

    private func hash(snapshot: SelectionSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.text)
        hasher.combine(snapshot.sourceBundleID ?? "")
        switch snapshot.origin {
        case .accessibility: hasher.combine(1)
        case .clipboardCopy: hasher.combine(2)
        }
        return hasher.finalize()
    }

    private func profileName(_ profile: CaptureProfile) -> String {
        switch profile {
        case .standard:
            return "standard"
        case .wechat:
            return "wechat"
        }
    }
}
