import Foundation
import ServiceManagement

enum LaunchAtLoginError: LocalizedError {
    case unsupported
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return L10n.text(zhHans: "当前运行环境不支持开机启动（swift run 调试模式常见）。", en: "This runtime does not support launch at login, which is common in `swift run` debug sessions.")
        case .operationFailed(let message):
            return message
        }
    }
}

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    func currentStatus() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 4 {
                throw LaunchAtLoginError.unsupported
            }
            throw LaunchAtLoginError.operationFailed(error.localizedDescription)
        }
    }
}
