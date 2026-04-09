import Foundation

enum RecognitionSlotKind: Equatable {
    case textCount
    case fileCount
    case screenshotSize
}

struct ScreenshotDimensionValue: Equatable {
    var width: Int
    var height: Int
}

struct RecognitionSlotState: Equatable {
    let kind: RecognitionSlotKind
    var count: Int
    var statusText: String?
    var dimensions: ScreenshotDimensionValue?

    static func textCount(count: Int = 0, statusText: String? = nil) -> RecognitionSlotState {
        RecognitionSlotState(
            kind: .textCount,
            count: count,
            statusText: statusText,
            dimensions: nil
        )
    }

    static func fileCount(count: Int = 0, statusText: String? = nil) -> RecognitionSlotState {
        RecognitionSlotState(
            kind: .fileCount,
            count: count,
            statusText: statusText,
            dimensions: nil
        )
    }

    static func screenshotSize(width: Int = 0, height: Int = 0, statusText: String? = nil) -> RecognitionSlotState {
        RecognitionSlotState(
            kind: .screenshotSize,
            count: 0,
            statusText: statusText,
            dimensions: ScreenshotDimensionValue(
                width: max(0, width),
                height: max(0, height)
            )
        )
    }
}

struct SkillSlotState: Equatable {
    let slotIndex: Int
    let skillID: String
}

struct MoreSlotState: Equatable {
    var skillIDs: [String]
}

struct ToolbarSlotLayoutState: Equatable {
    var recognitionSlot: RecognitionSlotState
    var skillSlots: [SkillSlotState]
    var moreSlot: MoreSlotState

    static var empty: ToolbarSlotLayoutState {
        ToolbarSlotLayoutState(
            recognitionSlot: .textCount(),
            skillSlots: [],
            moreSlot: MoreSlotState(skillIDs: [])
        )
    }
}
