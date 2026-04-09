import AppKit
import CoreGraphics
import Foundation

enum ScreenshotEditingTool: Equatable {
    case none
    case brush
    case rectangle
    case arrow
    case text
}

enum ScreenshotStrokeSize: String, CaseIterable, Equatable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small:
            return L10n.text(zhHans: "小", en: "Small")
        case .medium:
            return L10n.text(zhHans: "中", en: "Medium")
        case .large:
            return L10n.text(zhHans: "大", en: "Large")
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .small:
            return 3
        case .medium:
            return 6
        case .large:
            return 10
        }
    }

    var textFontSize: CGFloat {
        switch self {
        case .small:
            return 16
        case .medium:
            return 22
        case .large:
            return 30
        }
    }
}

enum ScreenshotAnnotationColor: String, CaseIterable, Equatable {
    case red
    case yellow
    case green
    case blue

    var nsColor: NSColor {
        switch self {
        case .red:
            return DesignTokens.Screenshot.Annotation.red
        case .yellow:
            return DesignTokens.Screenshot.Annotation.yellow
        case .green:
            return DesignTokens.Screenshot.Annotation.green
        case .blue:
            return DesignTokens.Screenshot.Annotation.blue
        }
    }

    var displayName: String {
        switch self {
        case .red:
            return L10n.text(zhHans: "红色", en: "Red")
        case .yellow:
            return L10n.text(zhHans: "黄色", en: "Yellow")
        case .green:
            return L10n.text(zhHans: "绿色", en: "Green")
        case .blue:
            return L10n.text(zhHans: "蓝色", en: "Blue")
        }
    }
}

struct ScreenshotBrushStrokeAnnotation: Equatable {
    let points: [CGPoint]
    let color: ScreenshotAnnotationColor
    let lineWidth: CGFloat
}

struct ScreenshotRectangleAnnotation: Equatable {
    let rect: CGRect
    let color: ScreenshotAnnotationColor
    let lineWidth: CGFloat
}

struct ScreenshotEllipseAnnotation: Equatable {
    let rect: CGRect
    let color: ScreenshotAnnotationColor
    let lineWidth: CGFloat
}

struct ScreenshotArrowAnnotation: Equatable {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let color: ScreenshotAnnotationColor
    let lineWidth: CGFloat
}

struct ScreenshotTextAnnotation: Equatable {
    let rect: CGRect
    let text: String
    let color: ScreenshotAnnotationColor
    let fontSize: CGFloat
}

enum ScreenshotOverlayAnnotation: Equatable {
    case brush(ScreenshotBrushStrokeAnnotation)
    case arrow(ScreenshotArrowAnnotation)
    case rectangle(ScreenshotRectangleAnnotation)
    case ellipse(ScreenshotEllipseAnnotation)
    case text(ScreenshotTextAnnotation)
}

final class ScreenshotAnnotationEngine {
    struct StateSnapshot: Equatable {
        let committedAnnotations: [ScreenshotOverlayAnnotation]
        let selectedTextAnnotationIndex: Int?
    }

    private struct BrushDraft {
        let startPoint: CGPoint
        var freehandPoints: [CGPoint]
        var currentPoint: CGPoint
        var isStraightLine: Bool
        var ellipsePreviewRect: CGRect?
    }

    private enum InFlightInteraction {
        case none
        case brush(BrushDraft)
        case rectangle(startPoint: CGPoint, currentPoint: CGPoint, modifiers: NSEvent.ModifierFlags)
        case arrow(startPoint: CGPoint, currentPoint: CGPoint)
    }

    private var committedAnnotations: [ScreenshotOverlayAnnotation] = []
    private var inFlightInteraction: InFlightInteraction = .none
    private(set) var selectedTextAnnotationIndex: Int?

    private(set) var selectedTool: ScreenshotEditingTool = .none
    private(set) var selectedStrokeSize: ScreenshotStrokeSize = .small
    private(set) var selectedColor: ScreenshotAnnotationColor = .red

    var annotations: [ScreenshotOverlayAnnotation] {
        if let inFlightAnnotation {
            return committedAnnotations + [inFlightAnnotation]
        }
        return committedAnnotations
    }

    var hasInFlightInteraction: Bool {
        if case .none = inFlightInteraction {
            return false
        }
        return true
    }

    func reset() {
        committedAnnotations = []
        inFlightInteraction = .none
        selectedTextAnnotationIndex = nil
        selectedTool = .none
        selectedStrokeSize = .small
        selectedColor = .red
    }

    func clearAnnotationsPreservingStyle() {
        committedAnnotations = []
        inFlightInteraction = .none
        selectedTextAnnotationIndex = nil
    }

    func setSelectedTool(_ tool: ScreenshotEditingTool) {
        let nextTool: ScreenshotEditingTool = (selectedTool == tool) ? .none : tool
        guard selectedTool != nextTool else { return }
        selectedTool = nextTool
        if nextTool != .text {
            selectedTextAnnotationIndex = nil
        }
        cancelInFlightInteraction()
    }

    func setSelectedStrokeSize(_ size: ScreenshotStrokeSize) {
        guard selectedStrokeSize != size else { return }
        selectedStrokeSize = size
    }

    func setSelectedColor(_ color: ScreenshotAnnotationColor) {
        guard selectedColor != color else { return }
        selectedColor = color
    }

    func makeStateSnapshot() -> StateSnapshot {
        StateSnapshot(
            committedAnnotations: committedAnnotations,
            selectedTextAnnotationIndex: selectedTextAnnotationIndex
        )
    }

    func restore(from snapshot: StateSnapshot) {
        committedAnnotations = snapshot.committedAnnotations
        inFlightInteraction = .none
        if let index = snapshot.selectedTextAnnotationIndex,
           committedAnnotations.indices.contains(index) {
            selectedTextAnnotationIndex = index
        } else {
            selectedTextAnnotationIndex = nil
        }
    }

    @discardableResult
    func beginInteraction(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        switch selectedTool {
        case .brush:
            inFlightInteraction = .brush(
                BrushDraft(
                    startPoint: point,
                    freehandPoints: [point],
                    currentPoint: point,
                    isStraightLine: modifiers.contains(.shift),
                    ellipsePreviewRect: nil
                )
            )
            return true
        case .rectangle:
            inFlightInteraction = .rectangle(startPoint: point, currentPoint: point, modifiers: modifiers)
            return true
        case .arrow:
            inFlightInteraction = .arrow(startPoint: point, currentPoint: point)
            return true
        case .text:
            return false
        case .none:
            return false
        }
    }

    @discardableResult
    func updateInteraction(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        switch inFlightInteraction {
        case var .brush(draft):
            if modifiers.contains(.shift) {
                draft.currentPoint = snappedBrushPoint(from: draft.startPoint, to: point)
                draft.isStraightLine = true
                draft.ellipsePreviewRect = nil
                inFlightInteraction = .brush(draft)
                return hypot(draft.currentPoint.x - draft.startPoint.x, draft.currentPoint.y - draft.startPoint.y) >= 6
            }

            let shouldAppend = draft.freehandPoints.last.map { hypot($0.x - point.x, $0.y - point.y) >= 1 } ?? true
            if shouldAppend {
                draft.freehandPoints.append(point)
            }
            draft.currentPoint = point
            draft.isStraightLine = false
            draft.ellipsePreviewRect = nil
            inFlightInteraction = .brush(draft)
            return draft.freehandPoints.count >= 2
        case let .rectangle(startPoint, _, _):
            inFlightInteraction = .rectangle(startPoint: startPoint, currentPoint: point, modifiers: modifiers)
            return hypot(point.x - startPoint.x, point.y - startPoint.y) >= 6
        case let .arrow(startPoint, _):
            inFlightInteraction = .arrow(startPoint: startPoint, currentPoint: point)
            return hypot(point.x - startPoint.x, point.y - startPoint.y) >= 6
        case .none:
            return false
        }
    }

    @discardableResult
    func finishInteraction() -> Bool {
        defer { cancelInFlightInteraction() }
        guard let annotation = finalizedInFlightAnnotation() else { return false }
        committedAnnotations.append(annotation)
        return true
    }

    func cancelInFlightInteraction() {
        inFlightInteraction = .none
    }

    func appendTextAnnotation(text: String, in rect: CGRect) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedAnnotations.append(
            .text(
                ScreenshotTextAnnotation(
                    rect: rect.integral,
                    text: trimmed,
                    color: selectedColor,
                    fontSize: selectedStrokeSize.textFontSize
                )
            )
        )
        selectedTextAnnotationIndex = committedAnnotations.indices.last
    }

    func clearTextSelection() {
        selectedTextAnnotationIndex = nil
    }

    @discardableResult
    func selectTextAnnotation(at point: CGPoint) -> Bool {
        for index in committedAnnotations.indices.reversed() {
            guard case let .text(annotation) = committedAnnotations[index] else { continue }
            let hitRect = annotation.rect.insetBy(dx: -10, dy: -8)
            if hitRect.contains(point) {
                selectedTextAnnotationIndex = index
                return true
            }
        }
        selectedTextAnnotationIndex = nil
        return false
    }

    var selectedTextAnnotationRect: CGRect? {
        guard let index = selectedTextAnnotationIndex,
              committedAnnotations.indices.contains(index),
              case let .text(annotation) = committedAnnotations[index] else {
            return nil
        }
        return annotation.rect
    }

    var selectedTextAnnotation: ScreenshotTextAnnotation? {
        guard let index = selectedTextAnnotationIndex,
              committedAnnotations.indices.contains(index),
              case let .text(annotation) = committedAnnotations[index] else {
            return nil
        }
        return annotation
    }

    @discardableResult
    func moveSelectedTextAnnotation(by delta: CGPoint, constrainedTo bounds: CGRect) -> Bool {
        guard let index = selectedTextAnnotationIndex,
              committedAnnotations.indices.contains(index),
              case let .text(annotation) = committedAnnotations[index] else {
            return false
        }

        let originalSize = annotation.rect.size
        var nextOrigin = CGPoint(
            x: annotation.rect.origin.x + delta.x,
            y: annotation.rect.origin.y + delta.y
        )
        var nextRect = CGRect(origin: nextOrigin, size: originalSize)
        if nextRect.minX < bounds.minX {
            nextOrigin.x = bounds.minX
        }
        if nextRect.maxX > bounds.maxX {
            nextOrigin.x = bounds.maxX - originalSize.width
        }
        if nextRect.minY < bounds.minY {
            nextOrigin.y = bounds.minY
        }
        if nextRect.maxY > bounds.maxY {
            nextOrigin.y = bounds.maxY - originalSize.height
        }
        nextOrigin.x = round(nextOrigin.x)
        nextOrigin.y = round(nextOrigin.y)
        nextRect = CGRect(origin: nextOrigin, size: originalSize)
        guard nextRect != annotation.rect else { return false }

        committedAnnotations[index] = .text(
            ScreenshotTextAnnotation(
                rect: nextRect,
                text: annotation.text,
                color: annotation.color,
                fontSize: annotation.fontSize
            )
        )
        return true
    }

    @discardableResult
    func deleteSelectedTextAnnotation() -> Bool {
        guard let index = selectedTextAnnotationIndex,
              committedAnnotations.indices.contains(index),
              case .text = committedAnnotations[index] else {
            return false
        }
        committedAnnotations.remove(at: index)
        selectedTextAnnotationIndex = nil
        return true
    }

    @discardableResult
    func updateSelectedTextAnnotation(text: String, rect: CGRect) -> Bool {
        guard let index = selectedTextAnnotationIndex,
              committedAnnotations.indices.contains(index),
              case let .text(existing) = committedAnnotations[index] else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        committedAnnotations[index] = .text(
            ScreenshotTextAnnotation(
                rect: rect.integral,
                text: trimmed,
                color: existing.color,
                fontSize: existing.fontSize
            )
        )
        return true
    }

    @discardableResult
    func promoteBrushInteractionToEllipseIfNeeded() -> Bool {
        guard case var .brush(draft) = inFlightInteraction,
              !draft.isStraightLine,
              let ellipseRect = detectBrushEllipsePreviewRect(from: draft.freehandPoints) else {
            return false
        }
        guard draft.ellipsePreviewRect != ellipseRect else { return true }
        draft.ellipsePreviewRect = ellipseRect
        inFlightInteraction = .brush(draft)
        return true
    }

    func drawCurrentAnnotations() {
        drawCurrentAnnotations(hidingSelectedTextAnnotation: false)
    }

    func drawCurrentAnnotations(hidingSelectedTextAnnotation: Bool) {
        drawAnnotations(
            displayAnnotations(hidingSelectedTextAnnotation: hidingSelectedTextAnnotation),
            offsetX: 0,
            offsetY: 0,
            dashedInFlightArrow: inFlightArrowAnnotation
        )
    }

    func drawAnnotationsForExport(in selectionRect: CGRect) {
        Self.drawAnnotations(annotations, inSelectionRect: selectionRect)
    }

    static func drawAnnotations(_ annotations: [ScreenshotOverlayAnnotation], inSelectionRect selectionRect: CGRect) {
        drawAnnotations(
            annotations,
            offsetX: -selectionRect.minX,
            offsetY: -selectionRect.minY,
            dashedInFlightArrow: nil
        )
    }

    private var inFlightAnnotation: ScreenshotOverlayAnnotation? {
        switch inFlightInteraction {
        case let .brush(draft):
            if let ellipsePreviewRect = draft.ellipsePreviewRect {
                return .ellipse(
                    ScreenshotEllipseAnnotation(
                        rect: ellipsePreviewRect,
                        color: selectedColor,
                        lineWidth: selectedStrokeSize.lineWidth
                    )
                )
            }
            if draft.isStraightLine {
                guard hypot(draft.currentPoint.x - draft.startPoint.x, draft.currentPoint.y - draft.startPoint.y) >= 6 else {
                    return nil
                }
                return .brush(
                    ScreenshotBrushStrokeAnnotation(
                        points: [draft.startPoint, draft.currentPoint],
                        color: selectedColor,
                        lineWidth: selectedStrokeSize.lineWidth
                    )
                )
            }
            guard draft.freehandPoints.count >= 2 else { return nil }
            return .brush(
                ScreenshotBrushStrokeAnnotation(
                    points: smoothedBrushPoints(from: draft.freehandPoints),
                    color: selectedColor,
                    lineWidth: selectedStrokeSize.lineWidth
                )
            )
        case let .rectangle(startPoint, currentPoint, modifiers):
            let rect = rectangleRect(from: startPoint, to: currentPoint, modifiers: modifiers)
            guard rect.width >= 6, rect.height >= 6 else { return nil }
            return .rectangle(
                ScreenshotRectangleAnnotation(
                    rect: rect,
                    color: selectedColor,
                    lineWidth: selectedStrokeSize.lineWidth
                )
            )
        case let .arrow(startPoint, currentPoint):
            guard hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) >= 6 else { return nil }
            return .arrow(
                ScreenshotArrowAnnotation(
                    startPoint: startPoint,
                    endPoint: currentPoint,
                    color: selectedColor,
                    lineWidth: selectedStrokeSize.lineWidth
                )
            )
        case .none:
            return nil
        }
    }

    private var inFlightArrowAnnotation: ScreenshotArrowAnnotation? {
        guard case let .arrow(startPoint, currentPoint) = inFlightInteraction,
              hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) >= 6 else {
            return nil
        }
        return ScreenshotArrowAnnotation(
            startPoint: startPoint,
            endPoint: currentPoint,
            color: selectedColor,
            lineWidth: selectedStrokeSize.lineWidth
        )
    }

    private func finalizedInFlightAnnotation() -> ScreenshotOverlayAnnotation? {
        switch inFlightInteraction {
        case let .brush(draft):
            if let ellipsePreviewRect = draft.ellipsePreviewRect {
                return .ellipse(
                    ScreenshotEllipseAnnotation(
                        rect: ellipsePreviewRect,
                        color: selectedColor,
                        lineWidth: selectedStrokeSize.lineWidth
                    )
                )
            }
            if draft.isStraightLine {
                return inFlightAnnotation
            }
            guard draft.freehandPoints.count >= 2 else { return nil }
            return .brush(
                ScreenshotBrushStrokeAnnotation(
                    points: smoothedBrushPoints(from: draft.freehandPoints),
                    color: selectedColor,
                    lineWidth: selectedStrokeSize.lineWidth
                )
            )
        case .rectangle, .arrow, .none:
            return inFlightAnnotation
        }
    }

    private func drawAnnotations(
        _ annotations: [ScreenshotOverlayAnnotation],
        offsetX: CGFloat,
        offsetY: CGFloat,
        dashedInFlightArrow: ScreenshotArrowAnnotation?
    ) {
        Self.drawAnnotations(
            annotations,
            offsetX: offsetX,
            offsetY: offsetY,
            dashedInFlightArrow: dashedInFlightArrow
        )
    }

    private static func drawAnnotations(
        _ annotations: [ScreenshotOverlayAnnotation],
        offsetX: CGFloat,
        offsetY: CGFloat,
        dashedInFlightArrow: ScreenshotArrowAnnotation?
    ) {
        guard !annotations.isEmpty else { return }
        for annotation in annotations {
            switch annotation {
            case let .brush(stroke):
                drawBrushStroke(stroke, offsetX: offsetX, offsetY: offsetY)
            case let .arrow(arrow):
                drawArrow(
                    arrow,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    dashed: dashedInFlightArrow == arrow
                )
            case let .rectangle(rectangle):
                drawRectangle(rectangle, offsetX: offsetX, offsetY: offsetY)
            case let .ellipse(ellipse):
                drawEllipse(ellipse, offsetX: offsetX, offsetY: offsetY)
            case let .text(text):
                drawText(text, offsetX: offsetX, offsetY: offsetY)
            }
        }
    }

    private static func drawBrushStroke(
        _ stroke: ScreenshotBrushStrokeAnnotation,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) {
        guard stroke.points.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = stroke.lineWidth
        path.move(to: CGPoint(x: stroke.points[0].x + offsetX, y: stroke.points[0].y + offsetY))
        for point in stroke.points.dropFirst() {
            path.line(to: CGPoint(x: point.x + offsetX, y: point.y + offsetY))
        }
        stroke.color.nsColor.setStroke()
        path.stroke()
    }

    private static func drawArrow(
        _ arrow: ScreenshotArrowAnnotation,
        offsetX: CGFloat,
        offsetY: CGFloat,
        dashed: Bool
    ) {
        let start = CGPoint(x: arrow.startPoint.x + offsetX, y: arrow.startPoint.y + offsetY)
        let end = CGPoint(x: arrow.endPoint.x + offsetX, y: arrow.endPoint.y + offsetY)
        guard hypot(end.x - start.x, end.y - start.y) >= 2 else { return }

        let path = NSBezierPath()
        path.lineWidth = arrow.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if dashed {
            let dashPattern: [CGFloat] = [6, 4]
            path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        }
        path.move(to: start)
        path.line(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowHeadLength = max(10, arrow.lineWidth * 2.4)
        let arrowHeadAngle = CGFloat.pi / 7
        let left = CGPoint(
            x: end.x - cos(angle - arrowHeadAngle) * arrowHeadLength,
            y: end.y - sin(angle - arrowHeadAngle) * arrowHeadLength
        )
        let right = CGPoint(
            x: end.x - cos(angle + arrowHeadAngle) * arrowHeadLength,
            y: end.y - sin(angle + arrowHeadAngle) * arrowHeadLength
        )
        path.move(to: end)
        path.line(to: left)
        path.move(to: end)
        path.line(to: right)

        arrow.color.nsColor.setStroke()
        path.stroke()
    }

    private static func drawRectangle(
        _ rectangle: ScreenshotRectangleAnnotation,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) {
        let path = NSBezierPath(
            rect: rectangle.rect.offsetBy(dx: offsetX, dy: offsetY)
        )
        path.lineWidth = rectangle.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        rectangle.color.nsColor.setStroke()
        path.stroke()
    }

    private static func drawEllipse(
        _ ellipse: ScreenshotEllipseAnnotation,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) {
        let path = NSBezierPath(
            ovalIn: ellipse.rect.offsetBy(dx: offsetX, dy: offsetY)
        )
        path.lineWidth = ellipse.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        ellipse.color.nsColor.setStroke()
        path.stroke()
    }

    private static func drawText(
        _ text: ScreenshotTextAnnotation,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) {
        let font = DesignTokens.Screenshot.Annotation.textFont(ofSize: text.fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: text.color.nsColor,
            .paragraphStyle: paragraphStyle
        ]
        let drawRect = text.rect.offsetBy(dx: offsetX, dy: offsetY)
        drawOutlinedText(
            text.text,
            in: drawRect,
            fillAttributes: fillAttributes,
            outlineColor: NSColor.white,
            outlineWidth: max(2, text.fontSize * 0.14)
        )
    }

    private static func drawOutlinedText(
        _ text: String,
        in rect: CGRect,
        fillAttributes: [NSAttributedString.Key: Any],
        outlineColor: NSColor,
        outlineWidth: CGFloat
    ) {
        let outlineAttributes = fillAttributes.merging([.foregroundColor: outlineColor]) { _, new in new }
        let offsets = outlineOffsets(radius: outlineWidth)
        let nsText = text as NSString

        for offset in offsets {
            let offsetRect = rect.offsetBy(dx: offset.width, dy: offset.height)
            nsText.draw(in: offsetRect, withAttributes: outlineAttributes)
        }

        nsText.draw(in: rect, withAttributes: fillAttributes)
    }

    private static func outlineOffsets(radius: CGFloat) -> [CGSize] {
        let clampedRadius = max(1, radius)
        let radii: [CGFloat] = [clampedRadius * 0.45, clampedRadius * 0.8, clampedRadius]
        var offsets: [CGSize] = []
        for radius in radii {
            for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 12) {
                offsets.append(
                    CGSize(
                        width: cos(angle) * radius,
                        height: sin(angle) * radius
                    )
                )
            }
        }
        return offsets
    }

    private func displayAnnotations(hidingSelectedTextAnnotation: Bool) -> [ScreenshotOverlayAnnotation] {
        guard hidingSelectedTextAnnotation,
              let selectedIndex = selectedTextAnnotationIndex else {
            return annotations
        }

        var visibleAnnotations = committedAnnotations
        if visibleAnnotations.indices.contains(selectedIndex),
           case .text = visibleAnnotations[selectedIndex] {
            visibleAnnotations.remove(at: selectedIndex)
        }
        if let inFlightAnnotation {
            visibleAnnotations.append(inFlightAnnotation)
        }
        return visibleAnnotations
    }

    private func normalizedRect(from startPoint: CGPoint, to currentPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        ).integral
    }

    private func rectangleRect(
        from startPoint: CGPoint,
        to currentPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> CGRect {
        let proportional = modifiers.contains(.shift)
        let symmetric = modifiers.contains(.option)

        var dx = currentPoint.x - startPoint.x
        var dy = currentPoint.y - startPoint.y

        if proportional {
            let edge = max(abs(dx), abs(dy))
            dx = dx >= 0 ? edge : -edge
            dy = dy >= 0 ? edge : -edge
        }

        if symmetric {
            return CGRect(
                x: startPoint.x - abs(dx),
                y: startPoint.y - abs(dy),
                width: abs(dx) * 2,
                height: abs(dy) * 2
            ).integral
        }

        return normalizedRect(
            from: startPoint,
            to: CGPoint(x: startPoint.x + dx, y: startPoint.y + dy)
        )
    }

    private func smoothedBrushPoints(from points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 4 else { return points }

        func smoothPass(_ source: [CGPoint]) -> [CGPoint] {
            guard source.count >= 4 else { return source }
            var result: [CGPoint] = [source[0]]

            for index in 1..<(source.count - 1) {
                let previous = source[index - 1]
                let current = source[index]
                let next = source[index + 1]
                let smoothedPoint = CGPoint(
                    x: (previous.x * 0.22) + (current.x * 0.56) + (next.x * 0.22),
                    y: (previous.y * 0.22) + (current.y * 0.56) + (next.y * 0.22)
                )
                result.append(smoothedPoint)
            }

            result.append(source[source.count - 1])
            return result
        }

        return smoothPass(smoothPass(points))
    }

    private func detectBrushEllipsePreviewRect(from points: [CGPoint]) -> CGRect? {
        guard points.count >= 10 else { return nil }
        let bounds = brushBounds(for: points)
        guard bounds.width >= 18, bounds.height >= 18 else { return nil }

        let travelLength = pathLength(for: points)
        let approximateEllipsePerimeter = CGFloat.pi * (3 * (bounds.width + bounds.height) - sqrt((3 * bounds.width + bounds.height) * (bounds.width + 3 * bounds.height)))
        let minEllipseTravel = approximateEllipsePerimeter * 0.42
        guard travelLength >= minEllipseTravel else { return nil }

        let ellipseContourScore = ellipseMatchScore(for: points, in: bounds)
        let ellipseCurvature = ellipseCurvatureScore(for: points, in: bounds)
        let ellipseScore = (ellipseContourScore * 0.62) + (ellipseCurvature * 0.38)
        let threshold: CGFloat = 0.61
        let aspectRatio = max(bounds.width, bounds.height) / max(1, min(bounds.width, bounds.height))
        let contourThreshold: CGFloat = aspectRatio >= 2.4 ? 0.44 : 0.5
        let curvatureThreshold: CGFloat = 0.24

        guard ellipseScore >= threshold,
              ellipseContourScore >= contourThreshold,
              ellipseCurvature >= curvatureThreshold else {
            return nil
        }

        return bounds
    }

    private func brushBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func ellipseMatchScore(for points: [CGPoint], in bounds: CGRect) -> CGFloat {
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        guard radiusX > 0, radiusY > 0 else { return 0 }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let tolerance: CGFloat = 0.4
        let matched = points.filter { point in
            let normalizedX = (point.x - center.x) / radiusX
            let normalizedY = (point.y - center.y) / radiusY
            let ellipseDistance = abs((normalizedX * normalizedX) + (normalizedY * normalizedY) - 1)
            return ellipseDistance <= tolerance
        }
        return CGFloat(matched.count) / CGFloat(points.count)
    }

    private func ellipseCurvatureScore(for points: [CGPoint], in bounds: CGRect) -> CGFloat {
        let spacing = max(6, min(bounds.width, bounds.height) * 0.06)
        let sampledPoints = resampledPoints(for: points, spacing: spacing)
        let turnAngles = sampledTurnAngles(for: sampledPoints)
        guard !turnAngles.isEmpty else { return 0 }

        let smoothTurns = turnAngles.filter { $0 >= 5 && $0 <= 62 }.count
        let sharpTurns = turnAngles.filter { $0 > 70 }.count
        let straightSteps = turnAngles.filter { $0 < 4 }.count

        let total = CGFloat(turnAngles.count)
        let smoothRatio = CGFloat(smoothTurns) / total
        let sharpRatio = CGFloat(sharpTurns) / total
        let straightRatio = CGFloat(straightSteps) / total
        let accumulatedTurn = turnAngles.reduce(CGFloat.zero, +)
        let turnCoverage = min(1, accumulatedTurn / 180)

        return max(
            0,
            (smoothRatio * 0.75)
                + (turnCoverage * 0.35)
                - (sharpRatio * 0.52)
                - (straightRatio * 0.14)
        )
    }

    private func pathLength(for points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }

    private func resampledPoints(for points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result: [CGPoint] = [points[0]]
        var previousAccepted = points[0]

        for point in points.dropFirst() {
            if hypot(point.x - previousAccepted.x, point.y - previousAccepted.y) >= spacing {
                result.append(point)
                previousAccepted = point
            }
        }

        if let last = points.last, result.last != last {
            result.append(last)
        }
        return result
    }

    private func sampledTurnAngles(for points: [CGPoint]) -> [CGFloat] {
        guard points.count >= 3 else { return [] }
        var turns: [CGFloat] = []

        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]

            let incoming = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
            let outgoing = CGPoint(x: next.x - current.x, y: next.y - current.y)
            let incomingLength = hypot(incoming.x, incoming.y)
            let outgoingLength = hypot(outgoing.x, outgoing.y)
            guard incomingLength > 0, outgoingLength > 0 else { continue }

            let dotProduct = incoming.x * outgoing.x + incoming.y * outgoing.y
            let normalized = max(-1, min(1, dotProduct / (incomingLength * outgoingLength)))
            let angle = acos(normalized) * 180 / .pi
            turns.append(angle)
        }

        return turns
    }

    private func snappedBrushPoint(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - start.x
        let dy = point.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0 else { return point }

        let angle = atan2(dy, dx)
        let snapStep = CGFloat.pi / 4
        let snappedAngle = (angle / snapStep).rounded() * snapStep
        return CGPoint(
            x: start.x + cos(snappedAngle) * distance,
            y: start.y + sin(snappedAngle) * distance
        )
    }
}
