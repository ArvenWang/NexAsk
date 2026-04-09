import AppKit
import ApplicationServices

private enum AXTextMarkerCompatibility {
    // Xcode 16.3's SDK no longer exposes these symbols to Swift, but the
    // underlying Accessibility API still accepts the documented raw names.
    static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    static let stringForTextMarkerRangeParameterizedAttribute = "AXStringForTextMarkerRange"
}

package enum SelectionOrigin {
    case accessibility
    case clipboardCopy
}

package struct SelectionSnapshot {
    package let text: String
    package let anchorPoint: CGPoint
    package let sourceBundleID: String?
    package let origin: SelectionOrigin
    package let replacementTarget: ReplacementTargetSnapshot?
}

package struct ReplacementTargetSnapshot {
    package let element: AXUIElement
    package let bundleID: String?
    package let role: String?
    package let frame: CGRect?
    package let selectedRange: NSRange?
    package let capturedValue: String?
    package let hasEditableSelection: Bool
    package let allowsSelectedTextWrite: Bool
    package let allowsValueWrite: Bool
    package let selectionWasInferred: Bool
}

package struct FileSelectionSnapshot {
    package let fileURLs: [URL]
    package let anchorPoint: CGPoint
    package let sourceBundleID: String?

    package var displayText: String {
        fileURLs.map(\.lastPathComponent).joined(separator: "\n")
    }
}

package struct ImageSelectionSnapshot {
    package let imageURL: URL
    package let anchorPoint: CGPoint
    package let selectionRect: CGRect
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let sourceBundleID: String?
    package let contentHints: ScreenshotContentHints?

    package var recognizedText: String? {
        contentHints?.recognizedText
    }

    package var displayText: String {
        imageURL.lastPathComponent
    }

    package var selectionPreviewText: String {
        contentHints?.previewText() ?? imageURL.lastPathComponent
    }
}

final class IncrementalTextInjector {
    typealias ScalarPoster = (UnicodeScalar) -> Bool

    private let queue: DispatchQueue
    private let delayMicroseconds: useconds_t
    private let postScalar: ScalarPoster

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.nexhub.selection-access.incremental-text-injector"),
        delayMicroseconds: useconds_t = 8_000,
        postScalar: @escaping ScalarPoster
    ) {
        self.queue = queue
        self.delayMicroseconds = delayMicroseconds
        self.postScalar = postScalar
    }

    func inject(_ text: String, completion: @escaping (Bool) -> Void) {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else {
            DispatchQueue.main.async {
                completion(false)
            }
            return
        }

        queue.async {
            var success = true

            for (index, scalar) in scalars.enumerated() {
                if !self.postScalar(scalar) {
                    success = false
                    break
                }

                if index < scalars.count - 1 {
                    usleep(self.delayMicroseconds)
                }
            }

            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
}

package enum SelectionAccess {
    package struct FinderSelectionCountResolution: Equatable {
        package let chosenCount: Int?
        package let usedSource: String
    }

    package enum WritebackResult {
        case success(method: String, diagnostics: String)
        case copiedToPasteboard(reason: String, diagnostics: String)
        case failure(reason: String, diagnostics: String)
    }

    package enum ReplaceSelectionResult {
        case success(diagnostics: String)
        case failure(reason: String, diagnostics: String)
    }

    private final class WritebackTrace {
        private(set) var lines: [String] = []

        func add(_ line: String) {
            lines.append(line)
        }

        func summary(limit: Int = 10) -> String {
            lines.suffix(limit).joined(separator: "\n")
        }

        func fullText() -> String {
            lines.joined(separator: "\n")
        }
    }

    private struct WritebackCandidate {
        let element: AXUIElement
        let role: String
        let frame: CGRect?
    }

    private struct WritebackProfile {
        let activationDelay: TimeInterval
        let needsExtraPreparation: Bool
        let prefersAppleScriptPaste: Bool
        let prefersUnicodeTextInjection: Bool
        let prefersIncrementalTyping: Bool
        let prefersComposerInjectionOnly: Bool
        let primesComposerBeforeDirectWrite: Bool
        let prefersValueWriteFirst: Bool
        let restrictDirectWriteToFocusedElementAfterPrime: Bool
        let allowsSelectedTextWrite: Bool
        let allowsForcedValueOverwrite: Bool
        let allowsRoleOnlyTextCandidates: Bool
        let scansAllWindowsForCandidates: Bool
        let prefersLargestWindow: Bool
        let composerXRatio: CGFloat
        let composerYRatio: CGFloat?
        let composerBottomInset: ClosedRange<CGFloat>
        let prefersFocusedContentFrame: Bool
        let composerInputWarmupDelay: TimeInterval
    }

    private struct SelectionReadInternal {
        let snapshot: SelectionSnapshot?
        let diagnostics: [String]
    }

    private static let incrementalTextInjector = IncrementalTextInjector(
        postScalar: postUnicodeScalar
    )

    private static func trimSelected(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func comparableSelectionText(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func compactComparableSelectionText(_ text: String?) -> String? {
        guard let normalized = comparableSelectionText(text) else { return nil }
        let filtered = normalized.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
        let compact = String(String.UnicodeScalarView(filtered))
        return compact.isEmpty ? nil : compact
    }

    private static func selectionTextMatchesExpected(_ actualText: String?, expected: String) -> Bool {
        guard let actual = comparableSelectionText(actualText) else { return false }
        if actual == expected { return true }
        if actual.contains(expected) || expected.contains(actual) { return true }
        if let compactActual = compactComparableSelectionText(actual),
           let compactExpected = compactComparableSelectionText(expected),
           (compactActual == compactExpected
                || compactActual.contains(compactExpected)
                || compactExpected.contains(compactActual)) {
            return true
        }
        return false
    }

    private static func pointerID(of element: AXUIElement) -> String {
        "\(Unmanaged.passUnretained(element).toOpaque())"
    }

    private static func describe(_ candidate: WritebackCandidate) -> String {
        let frameDescription: String
        if let frame = candidate.frame {
            frameDescription = "frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
        } else {
            frameDescription = "frame=nil"
        }
        return "role=\(candidate.role) \(frameDescription)"
    }

    private static func toAXElement(_ object: AnyObject?) -> AXUIElement? {
        guard let object else { return nil }
        return unsafeBitCast(object, to: AXUIElement.self)
    }

    private static func attributeNames(of element: AXUIElement) -> [String] {
        var cfNames: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &cfNames)
        guard result == .success, let cfNames else { return [] }
        return (cfNames as? [String]) ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        var roleObj: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObj)
        guard result == .success else { return nil }
        return roleObj as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenObj: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenObj)
        guard result == .success, let childrenObj else { return [] }
        guard let raw = childrenObj as? [AnyObject] else { return [] }
        return raw.compactMap { toAXElement($0) }
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var childrenObj: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &childrenObj)
        guard result == .success, let childrenObj else { return [] }
        guard let raw = childrenObj as? [AnyObject] else { return [] }
        return raw.compactMap { toAXElement($0) }
    }

    private static func supportsSelectionLikeAttributes(_ element: AXUIElement) -> Bool {
        let attrs = Set(attributeNames(of: element))
        let target: Set<String> = [
            kAXSelectedTextAttribute as String,
            kAXSelectedTextRangeAttribute as String,
            kAXSelectedTextRangesAttribute as String,
            AXTextMarkerCompatibility.selectedTextMarkerRangeAttribute
        ]
        if !attrs.intersection(target).isEmpty { return true }
        if let role = role(of: element),
           ["AXWebArea", "AXTextArea", "AXTextField", "AXTextView", "AXDocument", "AXStaticText"].contains(role) {
            return true
        }
        return false
    }

    private static func selectedTextFromRange(on element: AXUIElement, rangeValue: AnyObject) -> String? {
        var selectedObject: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &selectedObject
        )
        guard result == .success else { return nil }
        return trimSelected(selectedObject as? String)
    }

    private static func selectedTextFromTextMarkerRange(on element: AXUIElement, markerRangeValue: AnyObject) -> String? {
        var selectedObject: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            AXTextMarkerCompatibility.stringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRangeValue,
            &selectedObject
        )
        guard result == .success else { return nil }
        return trimSelected(selectedObject as? String)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var parentObj: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentObj)
        guard result == .success else { return nil }
        return toAXElement(parentObj)
    }

    private static func candidatesFromFocusedElement(_ focusedElement: AXUIElement, maxDepth: Int = 5) -> [AXUIElement] {
        var out: [AXUIElement] = [focusedElement]
        var cursor: AXUIElement? = focusedElement
        var steps = 0
        while steps < maxDepth, let node = cursor, let p = parent(of: node) {
            out.append(p)
            cursor = p
            steps += 1
        }
        return out
    }

    private static func collectDescendantCandidates(from root: AXUIElement, maxNodes: Int, diagnostics: inout [String]) -> [AXUIElement] {
        var queue: [AXUIElement] = children(of: root)
        var visited: Set<String> = []
        var out: [AXUIElement] = []

        while !queue.isEmpty, visited.count < maxNodes {
            let node = queue.removeFirst()
            let id = pointerID(of: node)
            if visited.contains(id) { continue }
            visited.insert(id)

            if supportsSelectionLikeAttributes(node) {
                out.append(node)
            }

            for child in children(of: node) {
                queue.append(child)
            }
        }

        diagnostics.append("descendantCandidates=\(out.count)/visited=\(visited.count)")
        return out
    }

    private static func readSelectedText(from element: AXUIElement, diagnostics: inout [String]) -> String? {
        var selectedObject: AnyObject?
        let selectedResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedObject)
        diagnostics.append("element.selectedText=\(selectedResult.rawValue)")
        if selectedResult == .success, let text = trimSelected(selectedObject as? String) {
            return text
        }

        var rangeObject: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObject)
        diagnostics.append("element.selectedTextRange=\(rangeResult.rawValue)")
        if rangeResult == .success, let rangeObject, let text = selectedTextFromRange(on: element, rangeValue: rangeObject) {
            return text
        }

        var rangesObject: AnyObject?
        let rangesResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangesAttribute as CFString, &rangesObject)
        diagnostics.append("element.selectedTextRanges=\(rangesResult.rawValue)")
        if rangesResult == .success,
           let ranges = rangesObject as? [AnyObject],
           let firstRange = ranges.first,
           let text = selectedTextFromRange(on: element, rangeValue: firstRange) {
            return text
        }

        var markerRangeObject: AnyObject?
        let markerRangeResult = AXUIElementCopyAttributeValue(
            element,
            AXTextMarkerCompatibility.selectedTextMarkerRangeAttribute as CFString,
            &markerRangeObject
        )
        diagnostics.append("element.selectedTextMarkerRange=\(markerRangeResult.rawValue)")
        if markerRangeResult == .success,
           let markerRangeObject,
           let text = selectedTextFromTextMarkerRange(on: element, markerRangeValue: markerRangeObject) {
            return text
        }

        return nil
    }

    private static func selectedText(on element: AXUIElement) -> String? {
        var diagnostics: [String] = []
        return readSelectedText(from: element, diagnostics: &diagnostics)
    }

    private static func readCurrentSelectionInternal(deepSearch: Bool) -> SelectionReadInternal {
        var diagnostics: [String] = []
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return SelectionReadInternal(snapshot: nil, diagnostics: ["frontmost=nil"])
        }

        let sourceBundleID = frontApp.bundleIdentifier ?? "unknown"
        diagnostics.append("frontmost=\(sourceBundleID)")
        if sourceBundleID == Bundle.main.bundleIdentifier {
            return SelectionReadInternal(snapshot: nil, diagnostics: diagnostics + ["frontmost=self"])
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var appFocusedObj: AnyObject?
        let appFocusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocusedObj)
        diagnostics.append("app.focusedUIElement=\(appFocusedResult.rawValue)")
        let appFocused = toAXElement(appFocusedObj)

        var focusedWindowObj: AnyObject?
        let focusedWindowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowObj)
        diagnostics.append("app.focusedWindow=\(focusedWindowResult.rawValue)")
        let focusedWindow = toAXElement(focusedWindowObj)

        let systemWide = AXUIElementCreateSystemWide()
        var systemFocusedObj: AnyObject?
        let systemFocusedResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &systemFocusedObj)
        diagnostics.append("system.focusedUIElement=\(systemFocusedResult.rawValue)")
        let systemFocused = toAXElement(systemFocusedObj)

        var candidates: [AXUIElement] = []
        if let appFocused {
            candidates.append(contentsOf: candidatesFromFocusedElement(appFocused))
        }
        if let focusedWindow {
            candidates.append(focusedWindow)
            candidates.append(contentsOf: candidatesFromFocusedElement(focusedWindow))
            if deepSearch {
                candidates.append(contentsOf: collectDescendantCandidates(from: focusedWindow, maxNodes: 220, diagnostics: &diagnostics))
            }
        }
        if let systemFocused {
            candidates.append(contentsOf: candidatesFromFocusedElement(systemFocused))
        }

        var dedup: [AXUIElement] = []
        var seen: Set<String> = []
        for c in candidates {
            let id = pointerID(of: c)
            if seen.contains(id) { continue }
            seen.insert(id)
            dedup.append(c)
        }
        diagnostics.append("candidates=\(dedup.count)")

        for (index, element) in dedup.enumerated() {
            diagnostics.append("candidate[\(index)] role=\(role(of: element) ?? "unknown")")
            if let selectedText = readSelectedText(from: element, diagnostics: &diagnostics) {
                return SelectionReadInternal(
                    snapshot: SelectionSnapshot(
                        text: selectedText,
                        anchorPoint: NSEvent.mouseLocation,
                        sourceBundleID: sourceBundleID,
                        origin: .accessibility,
                        replacementTarget: replacementTargetSnapshot(for: element, bundleID: sourceBundleID)
                    ),
                    diagnostics: diagnostics + ["selectedText=ok(\(selectedText.count))"]
                )
            }
        }

        return SelectionReadInternal(snapshot: nil, diagnostics: diagnostics + ["selectedText=nil"])
    }

    package static func readCurrentSelection(deepSearch: Bool = true) -> SelectionSnapshot? {
        readCurrentSelectionInternal(deepSearch: deepSearch).snapshot
    }

    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private static func runningApplication(for bundleID: String?) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        return NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
    }

    private static func applicationElement(for bundleID: String?) -> AXUIElement? {
        guard let app = runningApplication(for: bundleID) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func windows(for appElement: AXUIElement) -> [AXUIElement] {
        var windowsObject: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        if result == .success,
           let raw = windowsObject as? [AnyObject] {
            return raw.compactMap { toAXElement($0) }
        }

        return children(of: appElement).filter { role(of: $0) == kAXWindowRole as String }
    }

    private static func windowArea(_ element: AXUIElement) -> CGFloat {
        guard let frame = frame(of: element) else { return 0 }
        return frame.width * frame.height
    }

    private static func bestWindow(from windows: [AXUIElement], bundleID: String?) -> AXUIElement? {
        guard !windows.isEmpty else { return nil }
        let profile = writebackProfile(for: bundleID)
        if profile.prefersLargestWindow {
            return windows.max(by: { windowArea($0) < windowArea($1) })
        }
        return windows.first
    }

    private static func focusedElement(for bundleID: String?) -> AXUIElement? {
        if let bundleID,
           let appElement = applicationElement(for: bundleID) {
            var focusedObject: AnyObject?
            let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedObject)
            if result == .success, let focusedObject {
                return unsafeBitCast(focusedObject, to: AXUIElement.self)
            }

            if let fallback = windows(for: appElement)
                .flatMap({ collectDescendants(from: $0, maxNodes: 220) })
                .first(where: { role(of: $0) == "AXWebArea" }) {
                return fallback
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard result == .success, let focusedObject else { return nil }
        return unsafeBitCast(focusedObject, to: AXUIElement.self)
    }

    private static func systemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard result == .success, let focusedObject else { return nil }
        return unsafeBitCast(focusedObject, to: AXUIElement.self)
    }

    private static func focusedWindow(for bundleID: String?) -> AXUIElement? {
        guard let appElement = applicationElement(for: bundleID) else {
            return nil
        }

        let appWindows = windows(for: appElement)

        var windowObject: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        if result == .success, let windowObject {
            let focusedWindow = unsafeBitCast(windowObject, to: AXUIElement.self)
            if writebackProfile(for: bundleID).prefersLargestWindow,
               let best = bestWindow(from: appWindows, bundleID: bundleID),
               windowArea(best) > windowArea(focusedWindow) * 1.5 {
                return best
            }
            return focusedWindow
        }

        var mainWindowObject: AnyObject?
        let mainResult = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowObject)
        if mainResult == .success, let mainWindowObject {
            let mainWindow = unsafeBitCast(mainWindowObject, to: AXUIElement.self)
            if writebackProfile(for: bundleID).prefersLargestWindow,
               let best = bestWindow(from: appWindows, bundleID: bundleID),
               windowArea(best) > windowArea(mainWindow) * 1.2 {
                return best
            }
            return mainWindow
        }

        return bestWindow(from: appWindows, bundleID: bundleID)
    }

    private static func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private static func stringValue(of attribute: String, on element: AXUIElement) -> String? {
        var object: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard result == .success else { return nil }
        return object as? String
    }

    private static func boolValue(of attribute: String, on element: AXUIElement) -> Bool? {
        var object: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard result == .success, let object else { return nil }
        if let number = object as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionObject: AnyObject?
        var sizeObject: AnyObject?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionObject)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeObject)
        guard positionResult == .success,
              sizeResult == .success,
              let positionObject,
              let sizeObject,
              CFGetTypeID(positionObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = unsafeBitCast(positionObject, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeObject, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private static func selectedTextRange(on element: AXUIElement) -> NSRange? {
        var rangeObject: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObject)
        guard result == .success,
              let rangeValue = rangeObject,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func restoreSelectedTextRange(_ selectedRange: NSRange?, on element: AXUIElement) -> Bool {
        guard let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element) else {
            return false
        }

        var range = CFRange(location: selectedRange.location, length: selectedRange.length)
        guard let axValue = AXValueCreate(.cfRange, &range) else { return false }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axValue
        )
        return result == .success
    }

    private static func replaceViaSelectedText(on element: AXUIElement, replacement: String) -> Bool {
        guard isAttributeSettable(kAXSelectedTextAttribute as String, on: element) else { return false }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        )
        return result == .success
    }

    private static func replaceViaValueAttribute(on element: AXUIElement, replacement: String) -> Bool {
        guard isAttributeSettable(kAXValueAttribute as String, on: element) else { return false }
        guard let currentValue = stringValue(of: kAXValueAttribute as String, on: element) else { return false }

        let nsCurrentValue = currentValue as NSString
        let nextValue: String
        if let selectedRange = selectedTextRange(on: element),
           selectedRange.location != NSNotFound,
           selectedRange.location + selectedRange.length <= nsCurrentValue.length {
            nextValue = nsCurrentValue.replacingCharacters(in: selectedRange, with: replacement)
        } else if currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextValue = replacement
        } else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            nextValue as CFTypeRef
        )
        return result == .success
    }

    private static func replaceViaForcedValueOverwrite(on element: AXUIElement, replacement: String) -> Bool {
        guard isAttributeSettable(kAXValueAttribute as String, on: element) else { return false }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replacement as CFTypeRef
        )
        return result == .success
    }

    private static func elementReflectsWrite(_ element: AXUIElement, replacement: String) -> Bool {
        if let value = stringValue(of: kAXValueAttribute as String, on: element),
           value.contains(replacement) || value == replacement {
            return true
        }

        if let selected = selectedText(on: element),
           selected.contains(replacement) || selected == replacement {
            return true
        }

        return false
    }

    private static func hasEditableSelection(on element: AXUIElement, bundleID: String?) -> Bool {
        replacementTargetSnapshot(for: element, bundleID: bundleID).hasEditableSelection
    }

    private static func inferredSelectedRange(
        in currentValue: String?,
        copiedText: String?
    ) -> NSRange? {
        guard let currentValue,
              let copiedText = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !copiedText.isEmpty else {
            return nil
        }

        let nsCurrentValue = currentValue as NSString
        let firstRange = nsCurrentValue.range(of: copiedText)
        guard firstRange.location != NSNotFound else { return nil }

        let searchStart = firstRange.location + firstRange.length
        if searchStart < nsCurrentValue.length {
            let remainingRange = NSRange(location: searchStart, length: nsCurrentValue.length - searchStart)
            let secondRange = nsCurrentValue.range(of: copiedText, options: [], range: remainingRange)
            if secondRange.location != NSNotFound {
                return nil
            }
        }

        return firstRange
    }

    private static func replacementTargetSnapshot(
        for element: AXUIElement,
        bundleID: String?,
        copiedText: String? = nil
    ) -> ReplacementTargetSnapshot {
        let roleValue = role(of: element)
        let currentValue = stringValue(of: kAXValueAttribute as String, on: element)
        let explicitSelectedRange = selectedTextRange(on: element)
        let inferredSelectedRangeValue = inferredSelectedRange(in: currentValue, copiedText: copiedText)
        let selectedRangeValue = explicitSelectedRange ?? inferredSelectedRangeValue
        let selectedTextValue = selectedText(on: element)
        let allowsSelectedTextWrite = isAttributeSettable(kAXSelectedTextAttribute as String, on: element)
        let allowsValueWrite = isAttributeSettable(kAXValueAttribute as String, on: element)
        let supportsCarrier = isStandardWritableTextInput(element, bundleID: bundleID)
            || isContainerReplacementCandidate(
                element,
                bundleID: bundleID,
                copiedText: copiedText,
                currentValue: currentValue
            )

        return ReplacementTargetSnapshot(
            element: element,
            bundleID: bundleID,
            role: roleValue,
            frame: frame(of: element),
            selectedRange: selectedRangeValue,
            capturedValue: allowsValueWrite ? currentValue : nil,
            hasEditableSelection: supportsCarrier
                && (
                    (selectedTextValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    || ((selectedRangeValue?.location != NSNotFound) && (selectedRangeValue?.length ?? 0) > 0)
                ),
            allowsSelectedTextWrite: allowsSelectedTextWrite,
            allowsValueWrite: allowsValueWrite,
            selectionWasInferred: explicitSelectedRange == nil && inferredSelectedRangeValue != nil
        )
    }

    private static func isContainerReplacementCandidate(
        _ element: AXUIElement,
        bundleID: String?,
        copiedText: String?,
        currentValue: String?
    ) -> Bool {
        guard supportsContainerReplacementCandidates(bundleID: bundleID),
              let role = role(of: element),
              ["AXGroup", "AXWebArea", "AXScrollArea"].contains(role) else {
            return false
        }

        let inferredRange = inferredSelectedRange(in: currentValue, copiedText: copiedText)
        guard let inferredRange,
              inferredRange.location != NSNotFound,
              inferredRange.length > 0 else {
            return false
        }

        return isAttributeSettable(kAXValueAttribute as String, on: element)
            || isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element)
    }

    private static func supportsContainerReplacementCandidates(bundleID: String?) -> Bool {
        SourceAppPolicy.supportsContainerReplacementInference(bundleID: bundleID)
    }

    private static func activeReplacementTargetSnapshot(bundleID: String?, copiedText: String? = nil) -> ReplacementTargetSnapshot? {
        var candidates: [AXUIElement] = []
        let windowFrame = focusedWindow(for: bundleID).flatMap(frame(of:))

        if let focused = focusedElement(for: bundleID) {
            candidates.append(focused)
            candidates.append(contentsOf: candidatesFromFocusedElement(focused))
        }

        if let systemFocused = systemWideFocusedElement() {
            candidates.append(systemFocused)
            candidates.append(contentsOf: candidatesFromFocusedElement(systemFocused))
        }

        if let window = focusedWindow(for: bundleID) {
            candidates.append(window)
            candidates.append(contentsOf: collectDescendants(from: window, maxNodes: 220))
        }

        var seen: Set<String> = []
        var bestSnapshot: ReplacementTargetSnapshot?
        var bestScore = Int.min

        for candidate in candidates {
            let id = pointerID(of: candidate)
            if seen.contains(id) { continue }
            seen.insert(id)

            let snapshot = replacementTargetSnapshot(for: candidate, bundleID: bundleID, copiedText: copiedText)
            guard snapshot.hasEditableSelection else { continue }

            let score = replacementTargetScore(snapshot, windowFrame: windowFrame)
            if bestSnapshot == nil || score > bestScore {
                bestSnapshot = snapshot
                bestScore = score
            }
        }

        return bestSnapshot
    }

    private static func replacementTargetScore(
        _ snapshot: ReplacementTargetSnapshot,
        windowFrame: CGRect?
    ) -> Int {
        var score = 0

        switch snapshot.role {
        case "AXTextArea", "AXTextView":
            score += 140
        case "AXTextField", "AXComboBox", "AXSearchField":
            score += 110
        case "AXWebArea":
            score += 60
        case "AXGroup", "AXScrollArea":
            score += 30
        default:
            score += 10
        }

        if snapshot.allowsValueWrite { score += 28 }
        if snapshot.allowsSelectedTextWrite { score += 18 }

        if let selectedRange = snapshot.selectedRange,
           selectedRange.location != NSNotFound,
           selectedRange.length > 0 {
            score += snapshot.selectionWasInferred ? 34 : 72
        }

        if let capturedValue = snapshot.capturedValue, !capturedValue.isEmpty {
            score += 12
        }

        if let frame = snapshot.frame {
            let area = frame.width * frame.height
            if area >= 20_000 {
                score += 26
            } else if area >= 6_000 {
                score += 18
            } else if area >= 1_200 {
                score += 8
            } else {
                score -= 22
            }

            if let windowFrame {
                if frame.width <= windowFrame.width * 0.92,
                   frame.height <= windowFrame.height * 0.92 {
                    score += 10
                }
                if frame.minY >= windowFrame.minY + windowFrame.height * 0.45 {
                    score += 8
                }
            }
        } else {
            score -= 12
        }

        return score
    }

    private static func expectedValueAfterReplacement(
        capturedValue: String?,
        selectedRange: NSRange?,
        replacement: String
    ) -> String? {
        guard let capturedValue,
              let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.length > 0 else {
            return nil
        }

        let nsCaptured = capturedValue as NSString
        guard selectedRange.location + selectedRange.length <= nsCaptured.length else {
            return nil
        }
        return nsCaptured.replacingCharacters(in: selectedRange, with: replacement)
    }

    private static func verifyReplacement(
        on element: AXUIElement,
        replacement: String,
        replacementTarget: ReplacementTargetSnapshot?,
        targetMatchesCaptured: Bool
    ) -> (reflected: Bool, expectedMatch: Bool) {
        let reflected = elementReflectsWrite(element, replacement: replacement)
        guard targetMatchesCaptured,
              let replacementTarget,
              let expectedValue = expectedValueAfterReplacement(
                capturedValue: replacementTarget.capturedValue,
                selectedRange: replacementTarget.selectedRange,
                replacement: replacement
              ),
              let currentValue = stringValue(of: kAXValueAttribute as String, on: element) else {
            return (reflected, false)
        }

        return (reflected, currentValue == expectedValue)
    }

    private static func prefersTypedReplaceFallback(bundleID: String?) -> Bool {
        false
    }

    private static func replaceViaCapturedValueAttribute(
        on element: AXUIElement,
        selectedRange: NSRange?,
        capturedValue: String?,
        replacement: String
    ) -> Bool {
        guard let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              isAttributeSettable(kAXValueAttribute as String, on: element) else {
            return false
        }

        guard let baseValue = stringValue(of: kAXValueAttribute as String, on: element) ?? capturedValue else {
            return false
        }

        let nsBaseValue = baseValue as NSString
        guard selectedRange.location + selectedRange.length <= nsBaseValue.length else {
            return false
        }

        let nextValue = nsBaseValue.replacingCharacters(in: selectedRange, with: replacement)
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            nextValue as CFTypeRef
        )
        return result == .success
    }

    private static func isStandardWritableTextInput(_ element: AXUIElement, bundleID: String?) -> Bool {
        guard let role = role(of: element) else { return false }
        let inputRoles = ["AXTextArea", "AXTextField", "AXTextView", "AXComboBox", "AXSearchField"]
        guard inputRoles.contains(role) else { return false }
        if isAttributeSettable(kAXValueAttribute as String, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as String, on: element) {
            return true
        }

        let profile = writebackProfile(for: bundleID)
        if profile.allowsRoleOnlyTextCandidates, ["AXTextArea", "AXTextView"].contains(role) {
            return true
        }

        return false
    }

    private static func isContainerWritableCandidate(_ element: AXUIElement, bundleID: String?) -> Bool {
        let profile = writebackProfile(for: bundleID)
        guard profile.prefersUnicodeTextInjection else { return false }
        guard let role = role(of: element),
              ["AXGroup", "AXWebArea"].contains(role) else {
            return false
        }
        return isAttributeSettable(kAXValueAttribute as String, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as String, on: element)
    }

    private static func isWritableCandidate(_ element: AXUIElement, bundleID: String?) -> Bool {
        isStandardWritableTextInput(element, bundleID: bundleID) || isContainerWritableCandidate(element, bundleID: bundleID)
    }

    private static func isDirectWriteTextRole(_ element: AXUIElement) -> Bool {
        guard let elementRole = role(of: element) else { return false }
        return ["AXTextArea", "AXTextView", "AXTextField", "AXComboBox", "AXSearchField"].contains(elementRole)
    }

    private static func collectDescendants(from root: AXUIElement, maxNodes: Int = 260) -> [AXUIElement] {
        var queue: [AXUIElement] = children(of: root)
        var visited: Set<String> = []
        var out: [AXUIElement] = []

        while !queue.isEmpty, visited.count < maxNodes {
            let node = queue.removeFirst()
            let id = pointerID(of: node)
            if visited.contains(id) { continue }
            visited.insert(id)
            out.append(node)
            queue.append(contentsOf: children(of: node))
        }

        return out
    }

    private static func focusElement(_ element: AXUIElement) -> Bool {
        if isAttributeSettable(kAXFocusedAttribute as String, on: element) {
            return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func click(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            return false
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func clickCenter(of candidate: WritebackCandidate) -> Bool {
        guard let frame = candidate.frame else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return click(at: point)
    }

    private static func shouldClickCandidate(_ candidate: WritebackCandidate, bundleID: String?) -> Bool {
        if writebackProfile(for: bundleID).primesComposerBeforeDirectWrite {
            return false
        }
        if isContainerWritableCandidate(candidate.element, bundleID: bundleID) {
            return false
        }
        return candidate.frame != nil
    }

    private static func writebackProfile(for bundleID: String?) -> WritebackProfile {
        switch SourceAppPolicy.family(for: bundleID) {
        case .qq:
            return WritebackProfile(
                activationDelay: 0.2,
                needsExtraPreparation: true,
                prefersAppleScriptPaste: false,
                prefersUnicodeTextInjection: false,
                prefersIncrementalTyping: false,
                prefersComposerInjectionOnly: false,
                primesComposerBeforeDirectWrite: false,
                prefersValueWriteFirst: false,
                restrictDirectWriteToFocusedElementAfterPrime: false,
                allowsSelectedTextWrite: false,
                allowsForcedValueOverwrite: false,
                allowsRoleOnlyTextCandidates: false,
                scansAllWindowsForCandidates: false,
                prefersLargestWindow: false,
                composerXRatio: 0.57,
                composerYRatio: 0.86,
                composerBottomInset: 86...126,
                prefersFocusedContentFrame: false,
                composerInputWarmupDelay: 0.08
            )
        case .wechat:
            return WritebackProfile(
                activationDelay: 0.2,
                needsExtraPreparation: true,
                prefersAppleScriptPaste: false,
                prefersUnicodeTextInjection: false,
                prefersIncrementalTyping: false,
                prefersComposerInjectionOnly: false,
                primesComposerBeforeDirectWrite: false,
                prefersValueWriteFirst: false,
                restrictDirectWriteToFocusedElementAfterPrime: false,
                allowsSelectedTextWrite: false,
                allowsForcedValueOverwrite: false,
                allowsRoleOnlyTextCandidates: true,
                scansAllWindowsForCandidates: true,
                prefersLargestWindow: true,
                composerXRatio: 0.5,
                composerYRatio: 0.92,
                composerBottomInset: 88...138,
                prefersFocusedContentFrame: false,
                composerInputWarmupDelay: 0.08
            )
        case .lark:
            return WritebackProfile(
                activationDelay: 0.2,
                needsExtraPreparation: true,
                prefersAppleScriptPaste: false,
                prefersUnicodeTextInjection: false,
                prefersIncrementalTyping: false,
                prefersComposerInjectionOnly: true,
                primesComposerBeforeDirectWrite: false,
                prefersValueWriteFirst: false,
                restrictDirectWriteToFocusedElementAfterPrime: false,
                allowsSelectedTextWrite: false,
                allowsForcedValueOverwrite: false,
                allowsRoleOnlyTextCandidates: false,
                scansAllWindowsForCandidates: false,
                prefersLargestWindow: false,
                composerXRatio: 0.57,
                composerYRatio: 0.92,
                composerBottomInset: 56...90,
                prefersFocusedContentFrame: false,
                composerInputWarmupDelay: 0.24
            )
        case .wework:
            return WritebackProfile(
                activationDelay: 0.16,
                needsExtraPreparation: true,
                prefersAppleScriptPaste: false,
                prefersUnicodeTextInjection: false,
                prefersIncrementalTyping: false,
                prefersComposerInjectionOnly: false,
                primesComposerBeforeDirectWrite: false,
                prefersValueWriteFirst: false,
                restrictDirectWriteToFocusedElementAfterPrime: false,
                allowsSelectedTextWrite: true,
                allowsForcedValueOverwrite: false,
                allowsRoleOnlyTextCandidates: false,
                scansAllWindowsForCandidates: false,
                prefersLargestWindow: false,
                composerXRatio: 0.54,
                composerYRatio: nil,
                composerBottomInset: 88...138,
                prefersFocusedContentFrame: false,
                composerInputWarmupDelay: 0.08
            )
        case .other:
            return WritebackProfile(
                activationDelay: 0.12,
                needsExtraPreparation: false,
                prefersAppleScriptPaste: false,
                prefersUnicodeTextInjection: false,
                prefersIncrementalTyping: false,
                prefersComposerInjectionOnly: false,
                primesComposerBeforeDirectWrite: false,
                prefersValueWriteFirst: false,
                restrictDirectWriteToFocusedElementAfterPrime: false,
                allowsSelectedTextWrite: true,
                allowsForcedValueOverwrite: false,
                allowsRoleOnlyTextCandidates: false,
                scansAllWindowsForCandidates: false,
                prefersLargestWindow: false,
                composerXRatio: 0.54,
                composerYRatio: nil,
                composerBottomInset: 88...138,
                prefersFocusedContentFrame: false,
                composerInputWarmupDelay: 0.05
            )
        }
    }

    private static func activationDelay(for bundleID: String?) -> TimeInterval {
        writebackProfile(for: bundleID).activationDelay
    }

    private static func inputSettleDelay(for bundleID: String?, clickedCandidate: Bool) -> TimeInterval {
        let profile = writebackProfile(for: bundleID)
        if clickedCandidate {
            let base = profile.needsExtraPreparation ? 0.12 : 0.08
            return max(base, profile.composerInputWarmupDelay)
        }
        return profile.needsExtraPreparation ? 0.08 : 0.04
    }

    private static func prefersAppleScriptPaste(bundleID: String?) -> Bool {
        writebackProfile(for: bundleID).prefersAppleScriptPaste
    }

    private static func preferredComposerPoint(for bundleID: String?, frame targetFrame: CGRect) -> CGPoint? {
        guard let bundleID else { return nil }
        let profile = writebackProfile(for: bundleID)

        if let yRatio = profile.composerYRatio {
            return CGPoint(
                x: targetFrame.minX + targetFrame.width * profile.composerXRatio,
                y: targetFrame.minY + targetFrame.height * yRatio
            )
        }

        let computedInset = targetFrame.height * 0.08
        let bottomInset = min(max(computedInset, profile.composerBottomInset.lowerBound), profile.composerBottomInset.upperBound)

        return CGPoint(
            x: targetFrame.minX + targetFrame.width * profile.composerXRatio,
            y: targetFrame.minY + bottomInset
        )
    }

    private static func clickPreferredComposerArea(bundleID: String?, in window: AXUIElement?) -> Bool {
        guard let window else { return false }

        let profile = writebackProfile(for: bundleID)
        let baseFrame: CGRect?
        if profile.prefersFocusedContentFrame,
           let focused = focusedElement(for: bundleID),
           let focusedFrame = frame(of: focused) {
            baseFrame = focusedFrame
        } else {
            baseFrame = frame(of: window)
        }

        guard let targetFrame = baseFrame,
              let point = preferredComposerPoint(for: bundleID, frame: targetFrame) else {
            return false
        }
        return click(at: point)
    }

    private static func writebackCandidates(for bundleID: String?) -> [WritebackCandidate] {
        var candidates: [WritebackCandidate] = []
        let profile = writebackProfile(for: bundleID)
        let windowFrame = focusedWindow(for: bundleID).flatMap(frame(of:))

        if let focused = focusedElement(for: bundleID),
           isWritableCandidate(focused, bundleID: bundleID) {
            candidates.append(
                WritebackCandidate(
                    element: focused,
                    role: role(of: focused) ?? "unknown",
                    frame: frame(of: focused)
                )
            )
        }

        let candidateWindows: [AXUIElement]
        if profile.scansAllWindowsForCandidates,
           let appElement = applicationElement(for: bundleID) {
            candidateWindows = windows(for: appElement)
        } else if let window = focusedWindow(for: bundleID) {
            candidateWindows = [window]
        } else {
            candidateWindows = []
        }

        for window in candidateWindows {
            let descendants = collectDescendants(from: window)
            for element in descendants where isWritableCandidate(element, bundleID: bundleID) {
                candidates.append(
                    WritebackCandidate(
                        element: element,
                        role: role(of: element) ?? "unknown",
                        frame: frame(of: element)
                    )
                )
            }
        }

        var dedup: [WritebackCandidate] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let id = pointerID(of: candidate.element)
            if seen.contains(id) { continue }
            seen.insert(id)
            dedup.append(candidate)
        }

        func roleRank(_ role: String) -> Int {
            switch role {
            case "AXTextArea", "AXTextView":
                return 5
            case "AXTextField", "AXComboBox", "AXSearchField":
                return 4
            case "AXWebArea":
                return 3
            case "AXGroup":
                return 2
            default:
                return 1
            }
        }

        func paneRank(for candidate: WritebackCandidate) -> Int {
            guard let frame = candidate.frame,
                  let windowFrame else { return 0 }

            var rank = 0
            if frame.midX >= windowFrame.midX { rank += 2 }
            if frame.width < windowFrame.width * 0.95 { rank += 1 }
            if frame.height < windowFrame.height * 0.95 { rank += 1 }
            if profile.prefersFocusedContentFrame, frame.width <= windowFrame.width * 0.8 { rank += 1 }
            return rank
        }

        return dedup.sorted { lhs, rhs in
            let lhsPaneRank = paneRank(for: lhs)
            let rhsPaneRank = paneRank(for: rhs)
            if lhsPaneRank != rhsPaneRank { return lhsPaneRank > rhsPaneRank }

            let lhsRank = roleRank(lhs.role)
            let rhsRank = roleRank(rhs.role)
            if lhsRank != rhsRank { return lhsRank > rhsRank }

            let lhsWidth = lhs.frame?.width ?? 0
            let rhsWidth = rhs.frame?.width ?? 0
            if abs(lhsWidth - rhsWidth) > 1 { return lhsWidth > rhsWidth }

            let lhsY = lhs.frame?.minY ?? .greatestFiniteMagnitude
            let rhsY = rhs.frame?.minY ?? .greatestFiniteMagnitude
            if abs(lhsY - rhsY) > 1 { return lhsY < rhsY }

            let lhsHeight = lhs.frame?.height ?? 0
            let rhsHeight = rhs.frame?.height ?? 0
            return lhsHeight > rhsHeight
        }
    }

    static func diagnoseCurrentSelection() -> String {
        let result = readCurrentSelectionInternal(deepSearch: true)
        var lines = result.diagnostics
        if let snapshot = result.snapshot {
            let preview = snapshot.text.count > 80 ? String(snapshot.text.prefix(80)) + "..." : snapshot.text
            lines.append("preview=\(preview)")
        }
        return lines.joined(separator: "\n")
    }

    static func readClipboardSnapshot() -> SelectionSnapshot? {
        guard let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              sourceBundleID != Bundle.main.bundleIdentifier,
              let text = readPasteboardText() else {
            return nil
        }

        return SelectionSnapshot(
            text: text,
            anchorPoint: NSEvent.mouseLocation,
            sourceBundleID: sourceBundleID,
            origin: .clipboardCopy,
            replacementTarget: nil
        )
    }

    @discardableResult
    package static func replaceSelectedText(with replacement: String) -> Bool {
        guard let focusedElement = focusedElement(for: nil) else { return false }
        if replaceViaSelectedText(on: focusedElement, replacement: replacement) {
            return true
        }
        return replaceViaValueAttribute(on: focusedElement, replacement: replacement)
    }

    static func supportsReplacingSelectedText(
        sourceBundleID: String?,
        replacementTarget: ReplacementTargetSnapshot?,
        selectedText: String?
    ) -> Bool {
        if SourceAppPolicy.replaceSupportMode(bundleID: sourceBundleID) == .editableTargetOnly {
            return replacementTarget?.hasEditableSelection == true
        }

        if let replacementTarget {
            return replacementTarget.hasEditableSelection
        }

        if supportsKeyboardSelectionReplace(bundleID: sourceBundleID, selectedText: selectedText) {
            return true
        }

        if let sourceBundleID,
           let sourceFocusedElement = focusedElement(for: sourceBundleID),
           hasEditableSelection(on: sourceFocusedElement, bundleID: sourceBundleID) {
            return true
        }

        guard let focusedElement = focusedElement(for: nil) else { return false }
        return hasEditableSelection(on: focusedElement, bundleID: sourceBundleID)
    }

    private static func supportsKeyboardSelectionReplace(bundleID: String?, selectedText: String?) -> Bool {
        guard SourceAppPolicy.replaceSupportMode(bundleID: bundleID) == .keyboardSelectionFallback else {
            return false
        }

        guard let normalizedSelection = comparableSelectionText(selectedText) else {
            return false
        }

        return !normalizedSelection.isEmpty
    }

    package static func replaceSelectedText(
        with replacement: String,
        sourceBundleID: String?,
        replacementTarget: ReplacementTargetSnapshot?,
        selectedText: String?,
        completion: @escaping (ReplaceSelectionResult) -> Void
    ) {
        let normalized = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelection = comparableSelectionText(selectedText)
        var trace: [String] = [
            "bundle=\(sourceBundleID ?? "nil")",
            "textLength=\(normalized.count)"
        ]
        if let normalizedSelection {
            trace.append("selectionLength=\(normalizedSelection.count)")
        }

        guard !normalized.isEmpty else {
            completion(.failure(reason: "empty_text", diagnostics: trace.joined(separator: "\n")))
            return
        }

        func finish(_ result: ReplaceSelectionResult) {
            let payload: String
            switch result {
            case .success(let diagnostics):
                payload = "success\n\(diagnostics)"
            case .failure(let reason, let diagnostics):
                payload = "failure reason=\(reason)\n\(diagnostics)"
            }
            DiagnosticsLogger.shared.log("replace", payload)
            completion(result)
        }

        func attemptReplace() {
            let resolvedReplacementTarget = activeReplacementTargetSnapshot(
                bundleID: sourceBundleID,
                copiedText: selectedText
            ) ?? replacementTarget
            if let resolvedReplacementTarget {
                trace.append("resolvedTarget.role=\(resolvedReplacementTarget.role ?? "unknown")")
                trace.append("resolvedTarget.editable=\(resolvedReplacementTarget.hasEditableSelection)")
                trace.append("resolvedTarget.selectionInferred=\(resolvedReplacementTarget.selectionWasInferred)")
            } else {
                trace.append("resolvedTarget=nil")
            }

            func attemptKeyboardSelectionReplace(completion: @escaping (Bool) -> Void) {
                guard supportsKeyboardSelectionReplace(bundleID: sourceBundleID, selectedText: selectedText),
                      let normalizedSelection else {
                    completion(false)
                    return
                }

                let backup = backupPasteboard()
                let pboard = NSPasteboard.general
                pboard.clearContents()

                func finalizeKeyboardPaste() {
                    pboard.clearContents()
                    pboard.setString(normalized, forType: .string)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        let pasted = postPasteShortcut(for: sourceBundleID)
                        trace.append("keyboardReplace.pasted=\(pasted)")

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            restorePasteboard(backup)
                            if pasted {
                                finish(.success(diagnostics: trace.joined(separator: "\n")))
                                completion(true)
                            } else {
                                completion(false)
                            }
                        }
                    }
                }
                let copyIssued = postCommandC()
                trace.append("keyboardReplace.copyIssued=\(copyIssued)")
                guard copyIssued else {
                    restorePasteboard(backup)
                    completion(false)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    let copiedSelection = NSPasteboard.general.string(forType: .string)
                    let copyMatched = selectionTextMatchesExpected(copiedSelection, expected: normalizedSelection)
                    trace.append("keyboardReplace.copyMatched=\(copyMatched)")
                    trace.append("keyboardReplace.copyLength=\(copiedSelection?.count ?? 0)")

                    guard copyMatched else {
                        restorePasteboard(backup)
                        completion(false)
                        return
                    }

                    finalizeKeyboardPaste()
                }
            }

            func attemptDirectReplacement() {
                var candidates: [AXUIElement] = []
                if let resolvedReplacementTarget {
                    candidates.append(resolvedReplacementTarget.element)
                    trace.append("captured.role=\(resolvedReplacementTarget.role ?? "unknown")")
                    trace.append("captured.editable=\(resolvedReplacementTarget.hasEditableSelection)")
                }
                if let sourceBundleID,
                   let sourceFocusedElement = focusedElement(for: sourceBundleID) {
                    candidates.append(sourceFocusedElement)
                }
                if let focusedElement = focusedElement(for: nil) {
                    let focusedID = pointerID(of: focusedElement)
                    if !candidates.contains(where: { pointerID(of: $0) == focusedID }) {
                        candidates.append(focusedElement)
                    }
                }

                var dedupedCandidates: [AXUIElement] = []
                var seenCandidateIDs: Set<String> = []
                for candidate in candidates {
                    let candidateID = pointerID(of: candidate)
                    guard !seenCandidateIDs.contains(candidateID) else { continue }
                    seenCandidateIDs.insert(candidateID)
                    dedupedCandidates.append(candidate)
                }

                struct DeferredVerification {
                    let element: AXUIElement
                    let method: String
                    let targetMatchesCaptured: Bool
                }

                var deferredVerifications: [DeferredVerification] = []

                for candidate in dedupedCandidates {
                    trace.append("target.role=\(role(of: candidate) ?? "unknown")")
                    trace.append("target.editable=\(hasEditableSelection(on: candidate, bundleID: sourceBundleID))")
                    let capturedTargetMatches = resolvedReplacementTarget.map {
                        pointerID(of: $0.element) == pointerID(of: candidate)
                    } ?? false
                    let candidateIsEditable = capturedTargetMatches
                        ? (resolvedReplacementTarget?.hasEditableSelection ?? false)
                        : hasEditableSelection(on: candidate, bundleID: sourceBundleID)
                    guard candidateIsEditable else {
                        continue
                    }

                    let restoredSelection = capturedTargetMatches
                        ? restoreSelectedTextRange(resolvedReplacementTarget?.selectedRange, on: candidate)
                        : false
                    if capturedTargetMatches {
                        trace.append("target.selectionRestored=\(restoredSelection)")
                    }

                    func finalizeSuccessfulWrite(method: String) -> Bool {
                        let verification = verifyReplacement(
                            on: candidate,
                            replacement: normalized,
                            replacementTarget: resolvedReplacementTarget,
                            targetMatchesCaptured: capturedTargetMatches
                        )
                        trace.append("target.method=\(method)")
                        trace.append("target.reflected=\(verification.reflected)")
                        trace.append("target.expectedMatch=\(verification.expectedMatch)")
                        if verification.reflected || verification.expectedMatch {
                            finish(.success(diagnostics: trace.joined(separator: "\n")))
                            return true
                        }
                        deferredVerifications.append(
                            DeferredVerification(
                                element: candidate,
                                method: method,
                                targetMatchesCaptured: capturedTargetMatches
                            )
                        )
                        trace.append("target.deferredVerificationQueued=\(method)")
                        return false
                    }

                    if capturedTargetMatches,
                       let resolvedReplacementTarget,
                       resolvedReplacementTarget.allowsValueWrite,
                       replaceViaCapturedValueAttribute(
                            on: candidate,
                            selectedRange: resolvedReplacementTarget.selectedRange,
                            capturedValue: resolvedReplacementTarget.capturedValue,
                            replacement: normalized
                       ),
                       finalizeSuccessfulWrite(method: "captured_value") {
                        return
                    }

                    if !capturedTargetMatches,
                       replaceViaValueAttribute(on: candidate, replacement: normalized),
                       finalizeSuccessfulWrite(method: "value") {
                        return
                    }

                    let allowsSelectedTextWrite = capturedTargetMatches
                        ? (resolvedReplacementTarget?.allowsSelectedTextWrite ?? false)
                        : isAttributeSettable(kAXSelectedTextAttribute as String, on: candidate)
                    if !capturedTargetMatches,
                       allowsSelectedTextWrite,
                       replaceViaSelectedText(on: candidate, replacement: normalized),
                       finalizeSuccessfulWrite(method: "selected_text") {
                        return
                    }
                }

                func attemptPasteFallback() {
                    let backup = backupPasteboard()
                    let pboard = NSPasteboard.general
                    pboard.clearContents()
                    pboard.setString(normalized, forType: .string)

                    let targetElement = resolvedReplacementTarget?.element ?? focusedElement(for: sourceBundleID)
                    let focused: Bool
                    if resolvedReplacementTarget != nil {
                        focused = true
                    } else {
                        focused = targetElement.map(focusElement) ?? false
                    }
                    trace.append("pasteFallback.focused=\(focused)")

                    let restoredSelection = targetElement.map {
                        restoreSelectedTextRange(resolvedReplacementTarget?.selectedRange, on: $0)
                    } ?? false
                    trace.append("pasteFallback.selectionRestored=\(restoredSelection)")

                    let clicked = false
                    trace.append("pasteFallback.clicked=\(clicked)")

                    let settleDelay = inputSettleDelay(
                        for: sourceBundleID,
                        clickedCandidate: clicked || focused == false
                    )

                    let completePasteFallback: (Bool) -> Void = { pasted in
                        trace.append("pasteFallback.pasted=\(pasted)")

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            let verification = targetElement.map {
                                verifyReplacement(
                                    on: $0,
                                    replacement: normalized,
                                    replacementTarget: resolvedReplacementTarget,
                                    targetMatchesCaptured: resolvedReplacementTarget != nil
                                )
                            } ?? (reflected: false, expectedMatch: false)
                            trace.append("pasteFallback.reflected=\(verification.reflected)")
                            trace.append("pasteFallback.expectedMatch=\(verification.expectedMatch)")
                            restorePasteboard(backup)

                            if pasted, (verification.reflected || verification.expectedMatch) {
                                finish(.success(diagnostics: trace.joined(separator: "\n")))
                            } else {
                                finish(.failure(reason: "replace_not_supported", diagnostics: trace.joined(separator: "\n")))
                            }
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                        let usedTypedFallback = prefersTypedReplaceFallback(bundleID: sourceBundleID)
                        trace.append("pasteFallback.usedTyped=\(usedTypedFallback)")

                        if usedTypedFallback {
                            postUnicodeTextIncrementally(normalized) { incrementalSucceeded in
                                if incrementalSucceeded {
                                    completePasteFallback(true)
                                } else {
                                    completePasteFallback(postUnicodeText(normalized))
                                }
                            }
                        } else {
                            completePasteFallback(postPasteShortcut(for: sourceBundleID))
                        }
                    }
                }

                guard !deferredVerifications.isEmpty else {
                    attemptPasteFallback()
                    return
                }

                trace.append("target.deferredVerification.count=\(deferredVerifications.count)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    for verification in deferredVerifications {
                        let recheck = verifyReplacement(
                            on: verification.element,
                            replacement: normalized,
                            replacementTarget: resolvedReplacementTarget,
                            targetMatchesCaptured: verification.targetMatchesCaptured
                        )
                        trace.append("target.deferred.method=\(verification.method)")
                        trace.append("target.deferred.reflected=\(recheck.reflected)")
                        trace.append("target.deferred.expectedMatch=\(recheck.expectedMatch)")
                        if recheck.reflected || recheck.expectedMatch {
                            finish(.success(diagnostics: trace.joined(separator: "\n")))
                            return
                        }
                    }

                    attemptPasteFallback()
                }

            }

            if supportsKeyboardSelectionReplace(bundleID: sourceBundleID, selectedText: selectedText) {
                attemptKeyboardSelectionReplace { success in
                    guard !success else { return }
                    attemptDirectReplacement()
                }
                return
            }

            attemptDirectReplacement()
        }

        guard sourceBundleID != nil else {
            attemptReplace()
            return
        }

        activateApplication(bundleID: sourceBundleID) { activated in
            trace.append("activated=\(activated)")
            attemptReplace()
        }
    }

    package static func readPasteboardText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    static func writeTextToFocusedWindowField(_ replacement: String, sourceBundleID: String?) -> (success: Bool, diagnostics: String) {
        let normalized = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return (false, "abort=empty_text")
        }
        guard let window = focusedWindow(for: sourceBundleID) else {
            return (false, "window=nil")
        }

        let descendants = collectDescendants(from: window, maxNodes: 120)
        let rawCandidates = descendants.compactMap { element -> WritebackCandidate? in
            guard isStandardWritableTextInput(element, bundleID: sourceBundleID) else { return nil }
            let candidateRole = role(of: element) ?? "unknown"
            if candidateRole == "AXSearchField" {
                return nil
            }
            return WritebackCandidate(
                element: element,
                role: candidateRole,
                frame: frame(of: element)
            )
        }

        var seen: Set<String> = []
        let candidates = rawCandidates.filter { candidate in
            let id = pointerID(of: candidate.element)
            if seen.contains(id) { return false }
            seen.insert(id)
            return true
        }.sorted { lhs, rhs in
            let lhsWidth = lhs.frame?.width ?? 0
            let rhsWidth = rhs.frame?.width ?? 0
            if abs(lhsWidth - rhsWidth) > 1 { return lhsWidth > rhsWidth }

            let lhsY = lhs.frame?.minY ?? .greatestFiniteMagnitude
            let rhsY = rhs.frame?.minY ?? .greatestFiniteMagnitude
            if abs(lhsY - rhsY) > 1 { return lhsY < rhsY }

            let lhsHeight = lhs.frame?.height ?? 0
            let rhsHeight = rhs.frame?.height ?? 0
            return lhsHeight > rhsHeight
        }

        var trace: [String] = []
        trace.append("window=present")
        trace.append("candidates=\(candidates.count)")

        for (index, candidate) in candidates.prefix(4).enumerated() {
            trace.append("candidate[\(index)]=\(describe(candidate))")
            let focused = focusElement(candidate.element)
            trace.append("candidate[\(index)].focus=\(focused)")

            let selectedWrite = replaceViaSelectedText(on: candidate.element, replacement: normalized)
            if selectedWrite {
                let reflected = elementReflectsWrite(candidate.element, replacement: normalized)
                trace.append("candidate[\(index)].selected_text=\(reflected)")
                if reflected {
                    return (true, trace.joined(separator: "\n"))
                }
            }

            let valueWrite = replaceViaValueAttribute(on: candidate.element, replacement: normalized)
            if valueWrite {
                let reflected = elementReflectsWrite(candidate.element, replacement: normalized)
                trace.append("candidate[\(index)].value_write=\(reflected)")
                if reflected {
                    return (true, trace.joined(separator: "\n"))
                }
            }

            let forcedWrite = replaceViaForcedValueOverwrite(on: candidate.element, replacement: normalized)
            if forcedWrite {
                let reflected = elementReflectsWrite(candidate.element, replacement: normalized)
                trace.append("candidate[\(index)].forced_value=\(reflected)")
                if reflected {
                    return (true, trace.joined(separator: "\n"))
                }
            }
        }

        return (false, trace.joined(separator: "\n"))
    }

    private struct PasteboardBackup {
        let items: [NSPasteboardItem]
    }

    private static func backupPasteboard() -> PasteboardBackup {
        let pboard = NSPasteboard.general
        let cloned: [NSPasteboardItem] = (pboard.pasteboardItems ?? []).map { old in
            let item = NSPasteboardItem()
            for type in old.types {
                if let data = old.data(forType: type) {
                    item.setData(data, forType: type)
                } else if let text = old.string(forType: type) {
                    item.setString(text, forType: type)
                }
            }
            return item
        }
        return PasteboardBackup(items: cloned)
    }

    private static func restorePasteboard(_ backup: PasteboardBackup) {
        let pboard = NSPasteboard.general
        pboard.clearContents()
        if !backup.items.isEmpty {
            _ = pboard.writeObjects(backup.items)
        }
    }

    private static func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postCommandX() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postCommandVViaAppleScript() -> Bool {
        let scriptSource = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else {
            return false
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    private static func postPasteShortcut(for bundleID: String?) -> Bool {
        if prefersAppleScriptPaste(bundleID: bundleID) {
            return postCommandVViaAppleScript() || postCommandV()
        }
        return postCommandV() || postCommandVViaAppleScript()
    }

    private static func executeAppleScript(_ source: String) -> (descriptor: NSAppleEventDescriptor?, error: NSDictionary?) {
        guard let script = NSAppleScript(source: source) else {
            return (nil, ["reason": "compile_failed"])
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        return (descriptor, errorInfo)
    }

    private static func postUnicodeText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        let utf16 = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnicodeScalar(_ scalar: UnicodeScalar) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let payload = Array(String(scalar).utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        keyDown.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: payload)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnicodeTextIncrementally(_ text: String, completion: @escaping (Bool) -> Void) {
        incrementalTextInjector.inject(text, completion: completion)
    }

    private static func activateApplication(bundleID: String?, completion: @escaping (Bool) -> Void) {
        guard let bundleID,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            completion(false)
            return
        }

        let activated = app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay(for: bundleID)) {
            completion(activated)
        }
    }

    package static func writeTextToInput(
        _ replacement: String,
        sourceBundleID: String?,
        sourceInteractionContext: SourceInteractionContext = .empty,
        completion: @escaping (WritebackResult) -> Void
    ) {
        let normalized = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let trace = WritebackTrace()
        trace.add("bundle=\(sourceBundleID ?? "nil")")
        trace.add("textLength=\(normalized.count)")
        let writebackMode = sourceInteractionContext.writebackMode == .none
            ? SourceAppPolicy.writebackMode(bundleID: sourceBundleID, surface: .textSelection)
            : sourceInteractionContext.writebackMode
        trace.add("writebackMode=\(writebackMode.rawValue)")

        let finish: (WritebackResult) -> Void = { result in
            let payload: String
            switch result {
            case .success(let method, let diagnostics):
                payload = "success method=\(method)\n\(diagnostics)"
            case .copiedToPasteboard(let reason, let diagnostics):
                payload = "copied reason=\(reason)\n\(diagnostics)"
            case .failure(let reason, let diagnostics):
                payload = "failure reason=\(reason)\n\(diagnostics)"
            }
            DiagnosticsLogger.shared.log("writeback", payload)
            completion(result)
        }

        guard !normalized.isEmpty else {
            trace.add("abort=empty_text")
            finish(.failure(reason: "empty_text", diagnostics: trace.summary()))
            return
        }

        let fallbackPaste: (_ window: AXUIElement?) -> Void = { window in
            trace.add("fallbackPaste.begin")
            let backup = backupPasteboard()
            let pboard = NSPasteboard.general
            pboard.clearContents()
            pboard.setString(normalized, forType: .string)

            let profile = writebackProfile(for: sourceBundleID)
            let clickedComposer = clickPreferredComposerArea(bundleID: sourceBundleID, in: window)
            trace.add("fallbackPaste.clickedComposer=\(clickedComposer)")
            let pasteDelay = clickedComposer ? inputSettleDelay(for: sourceBundleID, clickedCandidate: true) : 0

            let performPaste = {
                func verifyFocusedWrite() -> Bool {
                    guard let focused = focusedElement(for: sourceBundleID) else { return false }
                    return elementReflectsWrite(focused, replacement: normalized)
                }

                func performVerifiedPaste() {
                    guard postPasteShortcut(for: sourceBundleID) else {
                        trace.add("fallbackPaste.method=paste_shortcut_failed")
                        restorePasteboard(backup)
                        finish(.copiedToPasteboard(reason: "paste_shortcut_failed", diagnostics: trace.summary()))
                        return
                    }

                    trace.add("fallbackPaste.method=\(clickedComposer ? "composer_click_paste" : "paste")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        let reflected = verifyFocusedWrite()
                        trace.add("fallbackPaste.paste.reflected=\(reflected)")
                        restorePasteboard(backup)
                        if reflected {
                            finish(.success(method: clickedComposer ? "composer_click_paste" : "paste", diagnostics: trace.summary()))
                        } else {
                            finish(.failure(reason: "paste_not_reflected", diagnostics: trace.summary()))
                        }
                    }
                }

                func attemptFocusedElementDirectWrite() -> Bool {
                    guard let focused = focusedElement(for: sourceBundleID) else {
                        trace.add("fallbackPaste.focused=nil")
                        return false
                    }

                    if replaceViaSelectedText(on: focused, replacement: normalized),
                       elementReflectsWrite(focused, replacement: normalized) {
                        trace.add("fallbackPaste.method=focused_selected_text")
                        restorePasteboard(backup)
                        finish(.success(method: "focused_selected_text", diagnostics: trace.summary()))
                        return true
                    }

                    if replaceViaForcedValueOverwrite(on: focused, replacement: normalized),
                       elementReflectsWrite(focused, replacement: normalized) {
                        trace.add("fallbackPaste.method=focused_forced_value")
                        restorePasteboard(backup)
                        finish(.success(method: "focused_forced_value", diagnostics: trace.summary()))
                        return true
                    }

                    if replaceViaValueAttribute(on: focused, replacement: normalized),
                       elementReflectsWrite(focused, replacement: normalized) {
                        trace.add("fallbackPaste.method=focused_value")
                        restorePasteboard(backup)
                        finish(.success(method: "focused_value", diagnostics: trace.summary()))
                        return true
                    }

                    trace.add("fallbackPaste.focused_write=failed")
                    return false
                }

                if clickedComposer,
                   !profile.prefersComposerInjectionOnly,
                   attemptFocusedElementDirectWrite() {
                    return
                }

                func performUnicodeTextInjection() -> Bool {
                    guard profile.prefersUnicodeTextInjection,
                          clickedComposer,
                          postUnicodeText(normalized) else {
                        return false
                    }

                    trace.add("fallbackPaste.method=unicode_text")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        let reflected = verifyFocusedWrite()
                        trace.add("fallbackPaste.unicode_text.reflected=\(reflected)")
                        if reflected {
                            restorePasteboard(backup)
                            finish(.success(method: "unicode_text", diagnostics: trace.summary()))
                            return
                        }

                        guard postPasteShortcut(for: sourceBundleID) else {
                            trace.add("fallbackPaste.unicode_text.paste_shortcut_failed")
                            restorePasteboard(backup)
                            finish(.copiedToPasteboard(reason: "paste_shortcut_failed", diagnostics: trace.summary()))
                            return
                        }

                        trace.add("fallbackPaste.unicode_text.fallback_to_paste=true")
                        performVerifiedPaste()
                    }
                    return true
                }

                if profile.prefersIncrementalTyping, clickedComposer {
                    postUnicodeTextIncrementally(normalized) { incrementalSucceeded in
                        if incrementalSucceeded {
                            trace.add("fallbackPaste.method=incremental_typing")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                let reflected = verifyFocusedWrite()
                                trace.add("fallbackPaste.incremental_typing.reflected=\(reflected)")
                                restorePasteboard(backup)
                                if reflected {
                                    finish(.success(method: "incremental_typing", diagnostics: trace.summary()))
                                } else {
                                    finish(.failure(reason: "incremental_typing_not_reflected", diagnostics: trace.summary()))
                                }
                            }
                            return
                        }

                        if performUnicodeTextInjection() {
                            return
                        }

                        performVerifiedPaste()
                    }
                    return
                }

                if performUnicodeTextInjection() {
                    return
                }

                performVerifiedPaste()
            }

            guard pasteDelay > 0 else {
                performPaste()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
                performPaste()
            }
        }

        let attemptWriteback = {
            let window = focusedWindow(for: sourceBundleID)
            trace.add("window=\(window == nil ? "nil" : "present")")
            let profile = writebackProfile(for: sourceBundleID)
            if profile.prefersComposerInjectionOnly {
                trace.add("mode=composer_injection_only")
                fallbackPaste(window)
                return
            }

            if writebackMode == .composerPaste {
                trace.add("mode=composer_paste")

                let backup = backupPasteboard()
                let pboard = NSPasteboard.general
                pboard.clearContents()
                pboard.setString(normalized, forType: .string)

                let clicked = clickPreferredComposerArea(bundleID: sourceBundleID, in: window)
                trace.add("composer.clicked=\(clicked)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    let pasted = postCommandV()
                    trace.add("composer.pasted=\(pasted)")

                    guard pasted else {
                        finish(.copiedToPasteboard(reason: "composer_paste_failed", diagnostics: trace.summary()))
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        restorePasteboard(backup)
                        finish(.success(method: "composer_paste", diagnostics: trace.summary()))
                    }
                }
                return
            }

            func buildTargets() -> [WritebackCandidate] {
                if profile.restrictDirectWriteToFocusedElementAfterPrime,
                   let focused = focusedElement(for: sourceBundleID) {
                    return [
                        WritebackCandidate(
                            element: focused,
                            role: role(of: focused) ?? "unknown",
                            frame: frame(of: focused)
                        )
                    ]
                }

                let candidates = writebackCandidates(for: sourceBundleID)
                let fallbackTarget = focusedElement(for: sourceBundleID).map {
                    WritebackCandidate(
                        element: $0,
                        role: role(of: $0) ?? "unknown",
                        frame: frame(of: $0)
                    )
                }
                return candidates.isEmpty ? (fallbackTarget.map { [$0] } ?? []) : candidates
            }

            func runDirectWrite(targets: [WritebackCandidate]) {
                trace.add("targets=\(targets.count)")
                for (index, candidate) in targets.prefix(6).enumerated() {
                    trace.add("target[\(index)]=\(describe(candidate))")
                }

                guard !targets.isEmpty else {
                    trace.add("targets.empty")
                    fallbackPaste(window)
                    return
                }

                func attemptCandidate(at index: Int) {
                    guard index < min(targets.count, 6) else {
                        trace.add("directWrite.exhausted")
                        fallbackPaste(window)
                        return
                    }

                    let candidate = targets[index]
                    trace.add("attempt[\(index)].candidate=\(describe(candidate))")
                    let focused = focusElement(candidate.element)
                    trace.add("attempt[\(index)].focused=\(focused)")
                    let clickedCandidate = shouldClickCandidate(candidate, bundleID: sourceBundleID) ? clickCenter(of: candidate) : false
                    trace.add("attempt[\(index)].clicked=\(clickedCandidate)")
                    let settleDelay = inputSettleDelay(
                        for: sourceBundleID,
                        clickedCandidate: clickedCandidate || focused == false
                    )

                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                        func attemptForcedValue() -> Bool {
                            guard profile.allowsForcedValueOverwrite,
                                  replaceViaForcedValueOverwrite(on: candidate.element, replacement: normalized) else { return false }
                            let reflected = elementReflectsWrite(candidate.element, replacement: normalized)
                            trace.add("attempt[\(index)].method=forced_value reflected=\(reflected)")
                            if reflected {
                                finish(.success(method: "forced_value", diagnostics: trace.summary()))
                                return true
                            }
                            return false
                        }

                        func attemptValue() -> Bool {
                            guard replaceViaValueAttribute(on: candidate.element, replacement: normalized) else { return false }
                            let reflected = elementReflectsWrite(candidate.element, replacement: normalized)
                            trace.add("attempt[\(index)].method=value reflected=\(reflected)")
                            if reflected {
                                finish(.success(method: "value", diagnostics: trace.summary()))
                                return true
                            }
                            return false
                        }

                        func attemptSelectedText() -> Bool {
                            guard profile.allowsSelectedTextWrite else { return false }
                            guard replaceViaSelectedText(on: candidate.element, replacement: normalized) else { return false }
                            let reflected = elementReflectsWrite(candidate.element, replacement: normalized)
                            trace.add("attempt[\(index)].method=selected_text reflected=\(reflected)")
                            if reflected {
                                finish(.success(method: "selected_text", diagnostics: trace.summary()))
                                return true
                            }
                            return false
                        }

                        let succeeded: Bool
                        if profile.prefersValueWriteFirst {
                            succeeded = attemptForcedValue() || attemptValue() || attemptSelectedText()
                        } else {
                            succeeded = attemptSelectedText() || attemptForcedValue() || attemptValue()
                        }

                        guard !succeeded else { return }
                        trace.add("attempt[\(index)].method=failed")
                        attemptCandidate(at: index + 1)
                    }
                }

                attemptCandidate(at: 0)
            }

            func primeComposerAndRetryIfNeeded() {
                let primed = clickPreferredComposerArea(bundleID: sourceBundleID, in: window)
                trace.add("composerPrimed=\(primed)")
                guard primed else {
                    fallbackPaste(window)
                    return
                }

                let delay = inputSettleDelay(for: sourceBundleID, clickedCandidate: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let retriedTargets = buildTargets()
                    trace.add("targetsAfterPrime=\(retriedTargets.count)")
                    runDirectWrite(targets: retriedTargets)
                }
            }

            if profile.primesComposerBeforeDirectWrite {
                primeComposerAndRetryIfNeeded()
                return
            }

            let initialTargets = buildTargets()
            if initialTargets.isEmpty, window != nil {
                trace.add("targetsInitial.empty")
                primeComposerAndRetryIfNeeded()
                return
            }

            runDirectWrite(targets: initialTargets)
        }

        if sourceBundleID != nil {
            activateApplication(bundleID: sourceBundleID) { _ in
                trace.add("activateApplication.done")
                attemptWriteback()
            }
        } else {
            attemptWriteback()
        }
    }

    static func captureSelectionBySyntheticCopy(completion: @escaping (SelectionSnapshot?) -> Void) {
        guard let sourceBundleID = frontmostBundleID(),
              sourceBundleID != Bundle.main.bundleIdentifier else {
            completion(nil)
            return
        }

        let initialReplacementTarget = activeReplacementTargetSnapshot(bundleID: sourceBundleID)

        let backup = backupPasteboard()
        let baseline = NSPasteboard.general.changeCount
        guard postCommandC() else {
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let text = NSPasteboard.general.changeCount == baseline ? nil : readPasteboardText()
            let replacementTarget = activeReplacementTargetSnapshot(bundleID: sourceBundleID, copiedText: text) ?? initialReplacementTarget
            restorePasteboard(backup)

            guard let text else {
                completion(nil)
                return
            }

            completion(
                SelectionSnapshot(
                    text: text,
                    anchorPoint: NSEvent.mouseLocation,
                    sourceBundleID: sourceBundleID,
                    origin: .clipboardCopy,
                    replacementTarget: replacementTarget
                )
            )
        }
    }

    private static let finderSelectionAttributes = [
        kAXSelectedChildrenAttribute as String,
        "AXSelectedRows",
        "AXSelectedItems",
        "AXSelectedCells"
    ]

    private static func finderSelectedCount(on element: AXUIElement) -> Int? {
        for attribute in finderSelectionAttributes {
            var object: AnyObject?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
            guard result == .success else { continue }
            guard let object else { return 0 }
            if let array = object as? [AnyObject] {
                return array.count
            }
            return 0
        }
        return nil
    }

    private static func finderContainerRoleScore(_ element: AXUIElement) -> CGFloat {
        switch role(of: element) ?? "" {
        case "AXList":
            return 4_000
        case "AXOutline":
            return 3_500
        case "AXTable":
            return 3_000
        case "AXBrowser":
            return 2_500
        case "AXScrollArea":
            return 2_000
        default:
            return 0
        }
    }

    private static func finderSupportsSelectionAttributes(_ element: AXUIElement) -> Bool {
        let names = Set(attributeNames(of: element))
        return !names.intersection(finderSelectionAttributes).isEmpty
    }

    private static func isFinderSidebarOrPathContainer(_ element: AXUIElement) -> Bool {
        let description = stringValue(of: kAXDescriptionAttribute as String, on: element) ?? ""
        if description.contains("边栏") || description.contains("路径") {
            return true
        }
        let title = stringValue(of: kAXTitleAttribute as String, on: element) ?? ""
        return title.contains("边栏")
    }

    private static func finderContentContainerScore(_ element: AXUIElement, rootArea: CGFloat) -> CGFloat? {
        let elementRole = role(of: element) ?? ""
        guard ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXGroup", "AXScrollArea"].contains(elementRole) else {
            return nil
        }
        guard !isFinderSidebarOrPathContainer(element) else { return nil }
        let description = stringValue(of: kAXDescriptionAttribute as String, on: element) ?? ""
        let subrole = stringValue(of: kAXSubroleAttribute as String, on: element) ?? ""
        let area = frame(of: element).map { $0.width * $0.height } ?? 0
        let areaRatio = area / max(1, rootArea)
        if areaRatio < 0.08 { return nil }

        var score = areaRatio * 1_000_000
        if elementRole == "AXList", subrole == "AXCollectionList" { score += 2_000_000 }
        if description.contains("图标视图")
            || description.contains("列表视图")
            || description.contains("分栏视图")
            || description.contains("画廊") {
            score += 1_000_000
        }
        return score
    }

    private static func finderSelectedFlagCount(in root: AXUIElement) -> Int {
        let nodes = [root] + collectDescendants(from: root, maxNodes: 2000)
        var count = 0
        for node in nodes {
            if boolValue(of: kAXSelectedAttribute as String, on: node) == true {
                count += 1
            }
        }
        return count
    }

    private static func finderEffectiveSelectedCount(on element: AXUIElement) -> Int {
        let directCount = finderSelectedCount(on: element) ?? 0
        let fallbackCount = directCount > 0 ? directCount : finderSelectedFlagCount(in: element)
        return max(directCount, fallbackCount)
    }

    private static func finderBestCountFromPath(
        start: AXUIElement?,
        rootArea: CGFloat
    ) -> (count: Int, score: CGFloat)? {
        var cursor = start
        var depth = 0
        while depth < 16, let node = cursor {
            if let score = finderContentContainerScore(node, rootArea: rootArea) {
                let effectiveCount = finderEffectiveSelectedCount(on: node)
                if effectiveCount > 0 {
                    return (effectiveCount, score)
                }
            }
            cursor = parent(of: node)
            depth += 1
        }
        return nil
    }

    private static func shouldPreferFinderCandidate(
        count: Int,
        score: CGFloat,
        bestCount: Int?,
        bestScore: CGFloat
    ) -> Bool {
        guard count > 0 else { return false }
        guard let bestCount else { return true }
        if count != bestCount {
            return count > bestCount
        }
        return score > bestScore
    }

    static func finderProcessIdentifier() -> pid_t? {
        runningApplication(for: "com.apple.finder")?.processIdentifier
    }

    static func finderSelectionObserverElements() -> [AXUIElement] {
        guard frontmostBundleID() == "com.apple.finder",
              let appElement = applicationElement(for: "com.apple.finder") else {
            return []
        }

        func appendUnique(_ element: AXUIElement?, to list: inout [AXUIElement], seen: inout Set<String>) {
            guard let element else { return }
            let id = pointerID(of: element)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            list.append(element)
        }

        func appendAncestorChain(from start: AXUIElement?, to list: inout [AXUIElement], seen: inout Set<String>) {
            var cursor = start
            var depth = 0
            while depth < 16, let node = cursor {
                appendUnique(node, to: &list, seen: &seen)
                cursor = parent(of: node)
                depth += 1
            }
        }

        var candidates: [AXUIElement] = []
        var seen: Set<String> = []

        let roots = [
            focusedWindow(for: "com.apple.finder"),
            bestWindow(from: windows(for: appElement), bundleID: "com.apple.finder"),
            appElement
        ].compactMap { $0 }

        for root in roots {
            appendUnique(root, to: &candidates, seen: &seen)
        }

        appendAncestorChain(from: focusedElement(for: "com.apple.finder"), to: &candidates, seen: &seen)

        let pointer = NSEvent.mouseLocation
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(pointer.x), Float(pointer.y), &hitElement) == .success {
            appendAncestorChain(from: hitElement, to: &candidates, seen: &seen)
        }

        var scoredElements: [(element: AXUIElement, score: CGFloat)] = []
        for root in roots {
            let rootArea = frame(of: root).map { max(1, $0.width * $0.height) } ?? 1
            let descendants = children(of: root) + children(of: root).flatMap(children(of:))
            for element in descendants {
                guard !isFinderSidebarOrPathContainer(element) else { continue }
                let selectionScore: CGFloat = finderSupportsSelectionAttributes(element) ? 10_000_000 : 0
                let containerScore = finderContentContainerScore(element, rootArea: rootArea) ?? 0
                let score = selectionScore + containerScore
                guard score > 0 else { continue }
                appendUnique(element, to: &candidates, seen: &seen)
                scoredElements.append((element, score))
            }
        }

        let prioritizedIDs = Set(
            scoredElements
                .sorted { lhs, rhs in lhs.score > rhs.score }
                .prefix(16)
                .map { pointerID(of: $0.element) }
        )

        return candidates.sorted { lhs, rhs in
            let lhsPriority = prioritizedIDs.contains(pointerID(of: lhs))
            let rhsPriority = prioritizedIDs.contains(pointerID(of: rhs))
            if lhsPriority != rhsPriority {
                return lhsPriority && !rhsPriority
            }
            return false
        }
    }

    static func finderPrimarySelectionContainer() -> AXUIElement? {
        guard frontmostBundleID() == "com.apple.finder",
              let window = focusedWindow(for: "com.apple.finder") else {
            return nil
        }

        func score(_ element: AXUIElement) -> CGFloat {
            guard !isFinderSidebarOrPathContainer(element) else { return 0 }
            let rootArea = frame(of: window).map { max(1, $0.width * $0.height) } ?? 1
            let containerScore = finderContentContainerScore(element, rootArea: rootArea) ?? 0
            let selectionScore: CGFloat = finderSupportsSelectionAttributes(element) ? 5_000_000 : 0
            return selectionScore + containerScore + finderContainerRoleScore(element)
        }

        func bestAncestor(from start: AXUIElement?) -> AXUIElement? {
            var cursor = start
            var best: (element: AXUIElement, score: CGFloat)?
            var depth = 0
            while depth < 12, let node = cursor {
                let currentScore = score(node)
                if currentScore > 0, (best == nil || currentScore > best!.score) {
                    best = (node, currentScore)
                }
                cursor = parent(of: node)
                depth += 1
            }
            return best?.element
        }

        // Finder's hit-tested element is noisy during marquee selection and can resolve to
        // unrelated rows/containers. The focused UI element is a much more reliable source
        // of truth for the active content pane in both list and icon views.
        if let bestFromFocus = bestAncestor(from: focusedElement(for: "com.apple.finder")) {
            return bestFromFocus
        }

        let pointer = NSEvent.mouseLocation
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(pointer.x), Float(pointer.y), &hitElement) == .success,
           let bestFromPointer = bestAncestor(from: hitElement) {
            return bestFromPointer
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = Set<String>()
        var best: (element: AXUIElement, score: CGFloat)?
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            let id = pointerID(of: node)
            if seen.contains(id) { continue }
            seen.insert(id)

            let currentScore = score(node)
            if currentScore > 0, (best == nil || currentScore > best!.score) {
                best = (node, currentScore)
            }

            if depth < 4 {
                for child in children(of: node) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return best?.element
    }

    static func finderSelectedItemCount(onPrimaryContainer preferredContainer: AXUIElement? = nil) -> Int? {
        guard frontmostBundleID() == "com.apple.finder" else { return nil }
        let container = preferredContainer ?? finderPrimarySelectionContainer()
        guard let container else { return nil }
        if let direct = finderSelectedCount(on: container) {
            return direct
        }
        return nil
    }

    private static func finderFastSelectionCount(alongPathFrom element: AXUIElement?) -> Int? {
        guard frontmostBundleID() == "com.apple.finder" else {
            return nil
        }

        let rootArea = focusedWindow(for: "com.apple.finder")
            .flatMap(frame(of:))
            .map { max(1, $0.width * $0.height) } ?? 1

        func countFromPath(start: AXUIElement?) -> Int? {
            guard let start else { return nil }

            if let direct = finderBestCountFromPath(start: start, rootArea: rootArea)?.count {
                return direct
            }

            var sawZero = false
            var cursor: AXUIElement? = start
            var depth = 0
            while depth < 16, let node = cursor {
                if finderSupportsSelectionAttributes(node),
                   !isFinderSidebarOrPathContainer(node) {
                    let count = finderEffectiveSelectedCount(on: node)
                    if count > 0 {
                        return count
                    }
                    sawZero = true
                }
                cursor = parent(of: node)
                depth += 1
            }
            return sawZero ? 0 : nil
        }

        if let count = countFromPath(start: element), count > 0 {
            return count
        }

        let primaryContainer = finderPrimarySelectionContainer()
        if let primaryContainer,
           pointerID(of: primaryContainer) != element.map(pointerID(of:)) {
            if let count = countFromPath(start: primaryContainer) {
                return count
            }
        }

        return countFromPath(start: focusedElement(for: "com.apple.finder"))
    }

    static func finderSelectionCount(forObserverElement element: AXUIElement?) -> Int? {
        finderFastSelectionCount(alongPathFrom: element)
    }

    private static func finderSelectionCountViaAX() -> Int? {
        guard frontmostBundleID() == "com.apple.finder" else {
            return nil
        }

        var focusedChainObservedZero = false
        if let focused = focusedElement(for: "com.apple.finder") {
            var cursor: AXUIElement? = focused
            var depth = 0
            while depth < 14, let node = cursor {
                if finderSupportsSelectionAttributes(node),
                   !isFinderSidebarOrPathContainer(node),
                   let count = finderSelectedCount(on: node) {
                    if count > 0 {
                        return count
                    }
                    focusedChainObservedZero = true
                }
                cursor = parent(of: node)
                depth += 1
            }
        }

        guard let appElement = applicationElement(for: "com.apple.finder") else {
            return nil
        }

        let roots = [
            focusedWindow(for: "com.apple.finder"),
            bestWindow(from: windows(for: appElement), bundleID: "com.apple.finder"),
            appElement
        ].compactMap { $0 }

        var bestCount: Int?
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        for root in roots {
            let rootArea = frame(of: root).map { max(1, $0.width * $0.height) } ?? 1
            let pointer = NSEvent.mouseLocation
            let systemWide = AXUIElementCreateSystemWide()
            var pointed: AXUIElement?
            let hit = AXUIElementCopyElementAtPosition(systemWide, Float(pointer.x), Float(pointer.y), &pointed)
            if hit == .success, let pointed {
                if let fromPointerPath = finderBestCountFromPath(start: pointed, rootArea: rootArea),
                   shouldPreferFinderCandidate(
                    count: fromPointerPath.count,
                    score: fromPointerPath.score + 5_000_000,
                    bestCount: bestCount,
                    bestScore: bestScore
                   ) {
                    bestCount = fromPointerPath.count
                    bestScore = fromPointerPath.score + 5_000_000
                }
            }

            let candidates = [root] + collectDescendants(from: root, maxNodes: 1200)
            for element in candidates {
                guard let score = finderContentContainerScore(element, rootArea: rootArea) else { continue }
                let effectiveCount = finderEffectiveSelectedCount(on: element)
                if shouldPreferFinderCandidate(
                    count: effectiveCount,
                    score: score,
                    bestCount: bestCount,
                    bestScore: bestScore
                ) {
                    bestCount = effectiveCount
                    bestScore = score
                }
            }
        }

        if let bestCount, bestCount > 0 {
            return bestCount
        }
        return focusedChainObservedZero ? 0 : nil
    }

    static func finderLiveSelectedItemCount() -> Int? {
        let axCount = finderSelectionCountViaAX()
        let scriptCount = finderSelectedItemCountViaAppleScript()
        return resolveFinderSelectionCount(axCount: axCount, scriptCount: scriptCount, minimumUsefulCount: 1).chosenCount
    }

    static func resolveFinderSelectionCount(
        axCount: Int?,
        scriptCount: Int?,
        minimumUsefulCount: Int
    ) -> FinderSelectionCountResolution {
        let usableAX = axCount.flatMap { $0 >= minimumUsefulCount ? $0 : nil }
        let usableScript = scriptCount.flatMap { $0 >= minimumUsefulCount ? $0 : nil }

        switch (usableAX, usableScript) {
        case let (ax?, script?):
            return ax >= script
                ? FinderSelectionCountResolution(chosenCount: ax, usedSource: ax == script ? "ax" : "ax_over_script")
                : FinderSelectionCountResolution(chosenCount: script, usedSource: "script_over_ax")
        case let (ax?, nil):
            return FinderSelectionCountResolution(chosenCount: ax, usedSource: "ax")
        case let (nil, script?):
            return FinderSelectionCountResolution(chosenCount: script, usedSource: "script")
        case (nil, nil):
            return FinderSelectionCountResolution(
                chosenCount: axCount ?? scriptCount,
                usedSource: (axCount ?? scriptCount) == nil ? "none" : "fallback_low"
            )
        }
    }

    private static func finderSelectedItemCountViaAppleScript() -> Int? {
        let scriptSource = """
        tell application "Finder"
            return count of selection
        end tell
        """
        let result = executeAppleScript(scriptSource)
        if let error = result.error {
            DiagnosticsLogger.shared.log("finder.fileSelection", "appleScript count failed error=\(error)")
            return nil
        }
        guard let descriptor = result.descriptor else {
            return nil
        }
        return Int(descriptor.int32Value)
    }

    static func captureFileSelectionBySyntheticCopy(completion: @escaping (FileSelectionSnapshot?) -> Void) {
        guard let sourceBundleID = frontmostBundleID(),
              sourceBundleID == "com.apple.finder" else {
            completion(nil)
            return
        }

        let backup = backupPasteboard()
        let baseline = NSPasteboard.general.changeCount
        guard postCommandC() else {
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let didChange = NSPasteboard.general.changeCount != baseline
            let urls = didChange
                ? (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                : []
            restorePasteboard(backup)

            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else {
                completion(nil)
                return
            }

            completion(
                FileSelectionSnapshot(
                    fileURLs: fileURLs,
                    anchorPoint: NSEvent.mouseLocation,
                    sourceBundleID: sourceBundleID
                )
            )
        }
    }
}
