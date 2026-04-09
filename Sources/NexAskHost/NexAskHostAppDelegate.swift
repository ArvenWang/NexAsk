import AppKit
import NexShared
import NexAskCore

final class NexAskHostAppDelegate: NSObject, NSApplicationDelegate {
    private let runtimeController: AppRuntimeController

    override init() {
        NexAskProductBootstrap.register()
        runtimeController = AppRuntimeController()
        super.init()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeController.applicationDidFinishLaunching(notification)
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        runtimeController.applicationWillTerminate(notification)
    }
}
