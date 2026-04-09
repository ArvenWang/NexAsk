import CoreGraphics
import Foundation

struct ScreenshotLockedSelectionState {
    private(set) var isReselecting = false
    private(set) var restoreRect: CGRect?
    private(set) var restoreAnchorPoint: CGPoint?

    mutating func reset() {
        isReselecting = false
        restoreRect = nil
        restoreAnchorPoint = nil
    }

    mutating func beginReselection(from rect: CGRect?, anchorPoint: CGPoint?) {
        isReselecting = rect != nil
        restoreRect = rect
        restoreAnchorPoint = anchorPoint
    }

    mutating func endReselection() {
        isReselecting = false
        restoreRect = nil
        restoreAnchorPoint = nil
    }
}
