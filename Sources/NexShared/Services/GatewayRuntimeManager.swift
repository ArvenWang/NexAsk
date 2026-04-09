import Foundation

extension Notification.Name {
    static let gatewayRuntimeDidChange = Notification.Name("nexhub.gatewayRuntimeDidChange")
}

struct GatewayLaunchResolver {
    private let fileManager: FileManager
    private let bundle: Bundle
    private let currentDirectoryPath: String

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.currentDirectoryPath = currentDirectoryPath
    }

    func resolveGatewayScriptURL() -> URL? {
        if let bundled = bundle.url(forResource: "local_gateway", withExtension: "py") {
            return bundled
        }

        let rootURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        guard looksLikeRepositoryRoot(rootURL) else { return nil }

        let developmentScriptURL = rootURL.appendingPathComponent("scripts/local_gateway.py")
        guard fileManager.fileExists(atPath: developmentScriptURL.path) else { return nil }
        return developmentScriptURL
    }

    private func looksLikeRepositoryRoot(_ rootURL: URL) -> Bool {
        let packageURL = rootURL.appendingPathComponent("Package.swift")
        let scriptURL = rootURL.appendingPathComponent("scripts/local_gateway.py")
        return fileManager.fileExists(atPath: packageURL.path)
            && fileManager.fileExists(atPath: scriptURL.path)
    }
}

enum GatewayRuntimePhase: String {
    case stopped
    case starting
    case ready
    case degraded
    case failed
}

enum GatewayRuntimeFailureReason: String {
    case dependencyMissing = "dependency_missing"
    case startupTimeout = "startup_timeout"
    case portUnavailable = "port_unavailable"
    case permission = "permission"
    case invalidConfiguration = "invalid_configuration"
    case processExited = "process_exited"
    case healthCheckFailed = "health_check_failed"
}

struct GatewayRuntimeSnapshot {
    let phase: GatewayRuntimePhase
    let failureReason: GatewayRuntimeFailureReason?
    let message: String
    let detail: String?
    let usesBundledPython: Bool
    let executablePath: String?
    let updatedAt: Date

    static let stopped = GatewayRuntimeSnapshot(
        phase: .stopped,
        failureReason: nil,
        message: L10n.text(zhHans: "本地 AI 运行时未启动。", en: "The local AI runtime is not running."),
        detail: nil,
        usesBundledPython: false,
        executablePath: nil,
        updatedAt: Date()
    )

    var isUsable: Bool {
        phase == .ready || phase == .degraded
    }

    var statusLabel: String {
        switch phase {
        case .stopped:
            return L10n.text(zhHans: "未启动", en: "Stopped")
        case .starting:
            return L10n.text(zhHans: "启动中", en: "Starting")
        case .ready:
            return L10n.text(zhHans: "已就绪", en: "Ready")
        case .degraded:
            return L10n.text(zhHans: "兼容运行", en: "Compatibility Mode")
        case .failed:
            return L10n.text(zhHans: "启动失败", en: "Failed")
        }
    }

    var userVisibleSummary: String {
        switch phase {
        case .stopped:
            return L10n.text(zhHans: "本地 AI 运行时还没有启动。", en: "The local AI runtime has not started yet.")
        case .starting:
            return L10n.text(zhHans: "本地 AI 运行时正在启动，通常几秒内会变为可用。", en: "The local AI runtime is starting and is usually ready within a few seconds.")
        case .ready:
            return L10n.text(zhHans: "本地 AI 运行时已就绪。", en: "The local AI runtime is ready.")
        case .degraded:
            return L10n.text(zhHans: "本地 AI 运行时已可用，但当前正以兼容模式运行。", en: "The local AI runtime is available, but it is currently running in compatibility mode.")
        case .failed:
            switch failureReason {
            case .dependencyMissing:
                return L10n.text(zhHans: "本地 AI 运行时缺少必要依赖，当前无法启动。", en: "The local AI runtime is missing required dependencies and cannot start.")
            case .startupTimeout:
                return L10n.text(zhHans: "本地 AI 运行时启动超时，当前无法处理云端技能。", en: "The local AI runtime timed out while starting, so cloud-backed skills are unavailable.")
            case .portUnavailable:
                return L10n.text(zhHans: "本地 AI 运行时端口被占用，当前无法正常启动。", en: "The local AI runtime port is already in use, so it cannot start normally.")
            case .permission:
                return L10n.text(zhHans: "本地 AI 运行时因为系统权限或执行限制没有成功启动。", en: "The local AI runtime could not start because of system permissions or execution restrictions.")
            case .invalidConfiguration:
                return L10n.text(zhHans: "本地 AI 运行时配置不完整，当前无法启动。", en: "The local AI runtime configuration is incomplete and cannot start.")
            case .processExited:
                return L10n.text(zhHans: "本地 AI 运行时启动后很快退出了。", en: "The local AI runtime exited shortly after launch.")
            case .healthCheckFailed:
                return L10n.text(zhHans: "本地 AI 运行时没有通过健康检查。", en: "The local AI runtime did not pass its health check.")
            case nil:
                return L10n.text(zhHans: "本地 AI 运行时当前不可用。", en: "The local AI runtime is currently unavailable.")
            }
        }
    }

    var recoverySuggestion: String {
        switch failureReason {
        case .dependencyMissing:
            return L10n.text(zhHans: "请重新安装应用，或重新打包后再覆盖安装。", en: "Please reinstall the app, or rebuild it and install it again.")
        case .startupTimeout:
            return L10n.text(zhHans: "请稍后重试；如果一直失败，可打开 AI 设置检查本地运行时状态。", en: "Please try again later. If it keeps failing, open AI Settings to inspect the local runtime status.")
        case .portUnavailable:
            return L10n.text(zhHans: "请关闭占用 8787 端口的进程后重试，或重启 NexHub。", en: "Close the process using port 8787 and try again, or restart NexHub.")
        case .permission:
            return L10n.text(zhHans: "请检查系统隐私与安全设置，确认应用可正常运行。", en: "Check macOS Privacy & Security settings and make sure the app is allowed to run.")
        case .invalidConfiguration:
            return L10n.text(zhHans: "请检查应用资源是否完整，然后重新打开 NexHub。", en: "Check that the app bundle resources are complete, then reopen NexHub.")
        case .processExited:
            return L10n.text(zhHans: "请重试启动；如果反复退出，重新安装通常能恢复。", en: "Try starting it again. If it keeps exiting, reinstalling usually fixes it.")
        case .healthCheckFailed:
            return L10n.text(zhHans: "请重试启动；如果仍失败，可打开 AI 设置查看详细状态。", en: "Try starting it again. If it still fails, open AI Settings for more detail.")
        case nil:
            return isUsable
                ? L10n.text(zhHans: "当前无需处理。", en: "No action is needed right now.")
                : L10n.text(zhHans: "请重试启动本地 AI 运行时。", en: "Please try starting the local AI runtime again.")
        }
    }

    var inlinePromptMessage: String {
        "\(userVisibleSummary) \(recoverySuggestion)"
    }
}

final class GatewayRuntimeManager {
    static let shared = GatewayRuntimeManager()
    private let stateLock = NSLock()
    private var snapshot: GatewayRuntimeSnapshot

    private init(
        launchResolver: GatewayLaunchResolver = GatewayLaunchResolver()
    ) {
        _ = launchResolver
        self.snapshot = Self.readySnapshot(detail: "built_in_runtime_initialized")
    }

    func currentSnapshot() -> GatewayRuntimeSnapshot {
        stateLock.withLock { snapshot }
    }

    func startIfNeeded() {
        markReady(detail: "start_if_needed")
    }

    func restart() {
        markReady(detail: "restart")
    }

    func stopIfStartedByApp() {
        stateLock.withLock {
            updateSnapshotLocked(
                GatewayRuntimeSnapshot(
                    phase: .stopped,
                    failureReason: nil,
                    message: L10n.text(zhHans: "内建 AI 运行时已停止。", en: "The built-in AI runtime is stopped."),
                    detail: "stopped_by_request",
                    usesBundledPython: false,
                    executablePath: Bundle.main.executablePath,
                    updatedAt: Date()
                )
            )
        }
    }

    func ensureReady(timeout: TimeInterval = 12.0) async -> Bool {
        _ = timeout
        markReady(detail: "ensure_ready")
        return true
    }

    private func markReady(detail: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        updateSnapshotLocked(Self.readySnapshot(detail: detail))
    }

    private static func readySnapshot(detail: String) -> GatewayRuntimeSnapshot {
        GatewayRuntimeSnapshot(
            phase: .ready,
            failureReason: nil,
            message: L10n.text(zhHans: "内建 AI 运行时已就绪。", en: "The built-in AI runtime is ready."),
            detail: detail,
            usesBundledPython: false,
            executablePath: Bundle.main.executablePath,
            updatedAt: Date()
        )
    }

    private func updateSnapshotLocked(_ newSnapshot: GatewayRuntimeSnapshot) {
        snapshot = newSnapshot
        let payload = newSnapshot
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .gatewayRuntimeDidChange, object: payload)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
