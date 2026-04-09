import Foundation

public final class AppRuntimeController: NSObject {
    private let runtime = NexHubRuntime()

    public override init() {
        super.init()
    }

    @MainActor
    public func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.applicationDidFinishLaunching(notification)
    }

    @MainActor
    public func applicationWillTerminate(_ notification: Notification) {
        runtime.applicationWillTerminate(notification)
    }
}
