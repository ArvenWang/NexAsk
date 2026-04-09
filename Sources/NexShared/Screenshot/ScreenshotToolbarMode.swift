import Foundation

enum ScreenshotToolbarMode: Equatable {
    case editing
    case scrollCapturing
    case scrollFinishing
    case longResult

    var isScrollFocused: Bool {
        switch self {
        case .scrollCapturing, .scrollFinishing:
            return true
        case .editing, .longResult:
            return false
        }
    }
}
