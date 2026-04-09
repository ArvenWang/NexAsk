import AppKit

package enum ResultMarkdownRenderer {
    private enum LocalFileResolutionCache {
        static let lock = NSLock()
        static var resolvedURLs: [String: URL] = [:]
        static var misses = Set<String>()
        static var directoryIndexes: [String: [String: [URL]]] = [:]
        static var warmingRoots = Set<String>()
    }

    enum LocalReferenceResolutionStrategy: Equatable {
        case explicitPath
        case exactRootChild
        case indexedSearch
    }

    package enum LocalLinkResolutionMode: Equatable {
        case synchronousFull
        case cachedOnly
    }

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case quote(String)
        case code(String)
    }

    package static func assistantAttributedText(
        text: String,
        highlightedSuffixLength: Int = 0,
        highlightedAlpha: CGFloat = 1,
        localLinkResolutionMode: LocalLinkResolutionMode = .synchronousFull
    ) -> NSAttributedString {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = markdownBlocks(from: normalized)
        let output = NSMutableAttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            switch block {
            case .heading(let level, let content):
                output.append(
                    inlineAttributedText(
                        content,
                        attributes: headingAttributes(level: level),
                        localLinkResolutionMode: localLinkResolutionMode
                    )
                )
            case .paragraph(let content):
                output.append(
                    inlineAttributedText(
                        content,
                        attributes: bodyAttributes(),
                        localLinkResolutionMode: localLinkResolutionMode
                    )
                )
            case .bullet(let content):
                let paragraphStyle = bulletParagraphStyle()
                let bulletPrefix = NSAttributedString(
                    string: "• ",
                    attributes: [
                        .font: DesignTokens.Typography.resultPanelBody,
                        .foregroundColor: DesignTokens.Color.textPrimary,
                        .paragraphStyle: paragraphStyle
                    ]
                )
                let bulletAttributes: [NSAttributedString.Key: Any] = [
                    .font: DesignTokens.Typography.resultPanelBody,
                    .foregroundColor: DesignTokens.Color.textPrimary,
                    .paragraphStyle: paragraphStyle
                ]
                let body: NSAttributedString
                if let linkedBody = linkedLocalReferenceText(
                    for: content,
                    attributes: bulletAttributes,
                    localLinkResolutionMode: localLinkResolutionMode
                ) {
                    body = linkedBody
                } else {
                    body = inlineAttributedText(
                        content,
                        attributes: bulletAttributes,
                        localLinkResolutionMode: localLinkResolutionMode
                    )
                }
                let line = NSMutableAttributedString(attributedString: bulletPrefix)
                line.append(body)
                output.append(line)
            case .quote(let content):
                output.append(
                    inlineAttributedText(
                        content,
                        attributes: quoteAttributes(),
                        localLinkResolutionMode: localLinkResolutionMode
                    )
                )
            case .code(let content):
                output.append(NSAttributedString(string: content, attributes: codeBlockAttributes()))
            }
        }

        if highlightedSuffixLength > 0 {
            let suffixLength = min(max(0, highlightedSuffixLength), output.length)
            if suffixLength > 0 {
                let suffixRange = NSRange(location: output.length - suffixLength, length: suffixLength)
                output.addAttribute(
                    .foregroundColor,
                    value: DesignTokens.Color.textPrimary.withAlphaComponent(highlightedAlpha),
                    range: suffixRange
                )
            }
        }

        return output
    }

    private static func markdownBlocks(from text: String) -> [Block] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var index = 0

        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while index < lines.count {
            let currentLine = lines[index]
            let current = trimmed(currentLine)
            if current.isEmpty {
                index += 1
                continue
            }

            if current.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let line = lines[index]
                    if trimmed(line).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(line)
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let headingMatch = current.range(of: #"^(#{1,3})\s+(.+)$"#, options: .regularExpression) {
                let line = String(current[headingMatch])
                let hashes = line.prefix { $0 == "#" }.count
                let content = trimmed(String(line.dropFirst(hashes)))
                blocks.append(.heading(level: hashes, text: content))
                index += 1
                continue
            }

            if let bulletMatch = current.range(of: #"^(?:[-*•]|\d+[.)])\s+(.+)$"#, options: .regularExpression) {
                let line = String(current[bulletMatch])
                let content = line.replacingOccurrences(
                    of: #"^(?:[-*•]|\d+[.)])\s+"#,
                    with: "",
                    options: .regularExpression
                )
                blocks.append(.bullet(content))
                index += 1
                continue
            }

            if current.hasPrefix(">") {
                let content = trimmed(current.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression))
                blocks.append(.quote(content))
                index += 1
                continue
            }

            var paragraphLines = [current]
            index += 1
            while index < lines.count {
                let next = trimmed(lines[index])
                if next.isEmpty || next.hasPrefix("```") {
                    break
                }
                if next.range(of: #"^(#{1,3})\s+.+$"#, options: .regularExpression) != nil ||
                    next.range(of: #"^(?:[-*•]|\d+[.)])\s+.+$"#, options: .regularExpression) != nil ||
                    next.hasPrefix(">") {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }

    private static func inlineAttributedText(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        linkifyLocalReferences: Bool = true,
        localLinkResolutionMode: LocalLinkResolutionMode = .synchronousFull
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var cursor = text.startIndex

        func appendPlain(_ string: String) {
            guard !string.isEmpty else { return }
            output.append(NSAttributedString(string: string, attributes: attributes))
        }

        while cursor < text.endIndex {
            let remaining = text[cursor...]

            if remaining.hasPrefix("**"),
               let boldStart = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex),
               let boldRange = text[boldStart...].range(of: "**") {
                let content = String(text[boldStart..<boldRange.lowerBound])
                output.append(NSAttributedString(string: content, attributes: emphasisAttributes(base: attributes)))
                cursor = boldRange.upperBound
                continue
            }

            if remaining.hasPrefix("`"),
               let codeStart = text.index(cursor, offsetBy: 1, limitedBy: text.endIndex),
               let codeRange = text[codeStart...].range(of: "`") {
                let content = String(text[codeStart..<codeRange.lowerBound])
                if linkifyLocalReferences,
                   localReferenceResolutionStrategy(for: content) != nil,
                   let localURL = resolvedLocalFileURL(for: content, localLinkResolutionMode: localLinkResolutionMode) {
                    output.append(NSAttributedString(string: content, attributes: linkAttributes(base: attributes, url: localURL)))
                } else if attributes[.link] != nil {
                    output.append(NSAttributedString(string: content, attributes: linkedInlineCodeAttributes(base: attributes)))
                } else {
                    output.append(NSAttributedString(string: content, attributes: inlineCodeAttributes(base: attributes)))
                }
                cursor = codeRange.upperBound
                continue
            }

            if remaining.hasPrefix("["),
               let closeBracket = remaining.range(of: "]("),
               let urlEnd = remaining[closeBracket.upperBound...].firstIndex(of: ")") {
                let labelStart = remaining.index(after: remaining.startIndex)
                let label = String(remaining[labelStart..<closeBracket.lowerBound])
                let urlText = String(remaining[closeBracket.upperBound..<urlEnd])
                if let url = URL(string: urlText), !label.isEmpty {
                    output.append(
                        NSAttributedString(
                            string: label,
                            attributes: mergedAttributes(
                                base: attributes,
                                extras: linkAttributes(base: attributes, url: url)
                            )
                        )
                    )
                    cursor = text.index(after: urlEnd)
                    continue
                }
            }

            appendPlain(String(text[cursor]))
            cursor = text.index(after: cursor)
        }

        return output
    }

    private static func mergedAttributes(
        base: [NSAttributedString.Key: Any],
        extras: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        base.merging(extras) { _, new in new }
    }

    private static func emphasisAttributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        mergedAttributes(
            base: base,
            extras: [
                .font: NSFont.systemFont(ofSize: DesignTokens.Typography.resultPanelBody.pointSize, weight: .bold),
                .foregroundColor: DesignTokens.Color.textPrimary.withAlphaComponent(0.98)
            ]
        )
    }

    private static func containsMarkdownSyntax(_ text: String) -> Bool {
        let candidates = ["```", "**", "`", "# ", "- ", "* ", "[", "> "]
        return candidates.contains { text.contains($0) }
    }

    private static func bodyAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        style.paragraphSpacing = 12
        return [
            .font: DesignTokens.Typography.resultPanelBody,
            .foregroundColor: DesignTokens.Color.textPrimary,
            .paragraphStyle: style
        ]
    }

    private static func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 3
        style.paragraphSpacing = 10
        let fontSize: CGFloat = switch level {
        case 1: 17
        case 2: 15
        default: 14
        }
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: DesignTokens.Color.textPrimary,
            .paragraphStyle: style
        ]
    }

    private static func quoteAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        style.paragraphSpacing = 12
        style.headIndent = 10
        style.firstLineHeadIndent = 10
        return [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: DesignTokens.Color.textSecondary,
            .paragraphStyle: style
        ]
    }

    private static func codeBlockAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        style.paragraphSpacing = 12
        style.headIndent = 12
        style.firstLineHeadIndent = 12
        return [
            .font: DesignTokens.Typography.resultPanelDetailMono,
            .foregroundColor: DesignTokens.Color.textPrimary,
            .backgroundColor: NSColor(calibratedWhite: 1, alpha: 0.08),
            .paragraphStyle: style
        ]
    }

    private static func inlineCodeAttributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        mergedAttributes(
            base: base,
            extras: [
                .font: DesignTokens.Typography.resultPanelDetailMono,
                .backgroundColor: NSColor(calibratedWhite: 1, alpha: 0.1)
            ]
        )
    }

    private static func linkedInlineCodeAttributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        mergedAttributes(
            base: base,
            extras: [
                .font: DesignTokens.Typography.resultPanelDetailMono
            ]
        )
    }

    private static func linkAttributes(
        base: [NSAttributedString.Key: Any],
        url: URL
    ) -> [NSAttributedString.Key: Any] {
        mergedAttributes(
            base: base,
            extras: [
                .foregroundColor: DesignTokens.Color.linkBlue,
                .link: url
            ]
        )
    }

    private static func linkedLocalReferenceText(
        for content: String,
        attributes: [NSAttributedString.Key: Any],
        localLinkResolutionMode: LocalLinkResolutionMode
    ) -> NSAttributedString? {
        if let linkedContent = linkedInlineLocalReferenceText(
            for: content,
            attributes: attributes,
            localLinkResolutionMode: localLinkResolutionMode
        ) {
            return linkedContent
        }

        guard let descriptorMatch = splitLocalDescriptorSuffix(from: content),
              let linkedLabel = linkedInlineLocalReferenceText(
                  for: descriptorMatch.label,
                  attributes: attributes,
                  localLinkResolutionMode: localLinkResolutionMode
              ) else {
            return nil
        }

        let output = NSMutableAttributedString(attributedString: linkedLabel)
        output.append(NSAttributedString(string: descriptorMatch.suffix, attributes: attributes))
        return output
    }

    private static func linkedInlineLocalReferenceText(
        for content: String,
        attributes: [NSAttributedString.Key: Any],
        localLinkResolutionMode: LocalLinkResolutionMode
    ) -> NSAttributedString? {
        let plainText = plainInlineText(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty,
              let localURL = resolvedLocalFileURL(
                  for: plainText,
                  localLinkResolutionMode: localLinkResolutionMode
              ) else {
            return nil
        }
        return inlineAttributedText(
            content,
            attributes: linkAttributes(base: attributes, url: localURL),
            linkifyLocalReferences: false,
            localLinkResolutionMode: localLinkResolutionMode
        )
    }

    private static func plainInlineText(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let remaining = text[cursor...]

            if remaining.hasPrefix("**"),
               let boldStart = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex),
               let boldRange = text[boldStart...].range(of: "**") {
                output.append(contentsOf: text[boldStart..<boldRange.lowerBound])
                cursor = boldRange.upperBound
                continue
            }

            if remaining.hasPrefix("`"),
               let codeStart = text.index(cursor, offsetBy: 1, limitedBy: text.endIndex),
               let codeRange = text[codeStart...].range(of: "`") {
                output.append(contentsOf: text[codeStart..<codeRange.lowerBound])
                cursor = codeRange.upperBound
                continue
            }

            if remaining.hasPrefix("["),
               let closeBracket = remaining.range(of: "]("),
               let urlEnd = remaining[closeBracket.upperBound...].firstIndex(of: ")") {
                let labelStart = remaining.index(after: remaining.startIndex)
                output.append(contentsOf: remaining[labelStart..<closeBracket.lowerBound])
                cursor = text.index(after: urlEnd)
                continue
            }

            output.append(text[cursor])
            cursor = text.index(after: cursor)
        }

        return output
    }

    private static func splitLocalDescriptorSuffix(from content: String) -> (label: String, suffix: String)? {
        let pattern = #"^(.*?)(\s+[—–-]\s+(?:文件夹|文件|folder|file))$"#
        guard let range = content.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(content[range])
        guard let suffixRange = matched.range(of: #"\s+[—–-]\s+(?:文件夹|文件|folder|file)$"#, options: .regularExpression) else {
            return nil
        }
        let label = String(matched[..<suffixRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(matched[suffixRange.lowerBound...])
        guard !label.isEmpty else { return nil }
        return (label, suffix)
    }

    package static func prewarmDefaultLocalReferenceIndexes() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true)
        ]
        roots.forEach(scheduleDirectoryIndexWarmup)
    }

    private enum ApproximateLocalMatchResult: Equatable {
        case match(URL)
        case noMatch
        case pendingWarmup
    }

    private static let directoryIndexWarmupQueue = DispatchQueue(
        label: "nexhub.result-markdown-renderer.directory-index",
        qos: .utility
    )

    private static func resolvedLocalFileURL(
        for rawValue: String,
        localLinkResolutionMode: LocalLinkResolutionMode
    ) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = cachedResolvedLocalFileURL(for: trimmed) {
            return cached
        }
        if isCachedLocalFileMiss(for: trimmed) {
            return nil
        }

        guard let strategy = localReferenceResolutionStrategy(for: trimmed) else {
            cacheResolvedLocalFileURL(nil, for: trimmed)
            return nil
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        if strategy == .explicitPath {
            let explicitURL = URL(fileURLWithPath: expanded).standardizedFileURL
            let resolved = fileManager.fileExists(atPath: explicitURL.path) ? explicitURL : nil
            cacheResolvedLocalFileURL(resolved, for: trimmed)
            return resolved
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let candidateRoots = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true)
        ]

        var matches: [URL] = []
        var pendingIndexedWarmup = false
        for root in candidateRoots {
            let candidate = root.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: candidate.path) {
                matches.append(candidate.standardizedFileURL)
            }
            if strategy == .indexedSearch {
                switch approximateLocalChildMatch(
                    named: trimmed,
                    in: root,
                    localLinkResolutionMode: localLinkResolutionMode
                ) {
                case .match(let fallback):
                    matches.append(fallback.standardizedFileURL)
                case .pendingWarmup:
                    pendingIndexedWarmup = true
                case .noMatch:
                    break
                }
            }
        }

        let resolved = Array(Set(matches)).sorted(by: preferredLocalURLOrder).first
        if let resolved {
            cacheResolvedLocalFileURL(resolved, for: trimmed)
        } else if !pendingIndexedWarmup {
            cacheResolvedLocalFileURL(nil, for: trimmed)
        }
        return resolved
    }

    static func localReferenceResolutionStrategy(for rawValue: String) -> LocalReferenceResolutionStrategy? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              trimmed.count <= 180 else {
            return nil
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return .explicitPath
        }

        let phraseDelimiters = CharacterSet(charactersIn: "，。！？：；,?!:;")
        if trimmed.rangeOfCharacter(from: phraseDelimiters) != nil {
            return nil
        }

        if trimmed.contains("/") {
            return .exactRootChild
        }

        let tokenCount = trimmed.split(whereSeparator: \.isWhitespace).count
        if tokenCount == 0 || tokenCount > 4 {
            return nil
        }

        if looksLikeFilename(trimmed) {
            return .indexedSearch
        }

        let containsPathPunctuation = trimmed.contains("_") || trimmed.contains("-") || trimmed.contains(".")
        let containsASCIIAlnum = trimmed.range(of: #"[A-Za-z0-9]"#, options: .regularExpression) != nil
        if containsPathPunctuation && containsASCIIAlnum {
            return .indexedSearch
        }

        if tokenCount == 1 && trimmed.count <= 32 {
            return .exactRootChild
        }

        return nil
    }

    private static func looksLikeFilename(_ value: String) -> Bool {
        let lastComponent = value.split(separator: "/").last.map(String.init) ?? value
        return lastComponent.range(of: #"\.[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil
    }

    private static func approximateLocalChildMatch(
        named rawName: String,
        in root: URL,
        localLinkResolutionMode: LocalLinkResolutionMode
    ) -> ApproximateLocalMatchResult {
        let normalizedTarget = normalizedLocalMatchName(rawName)
        if let cached = cachedDirectoryIndex(for: root),
           let cachedMatch = cached[normalizedTarget]?.sorted(by: preferredLocalURLOrder).first {
            return .match(cachedMatch)
        }
        switch localLinkResolutionMode {
        case .cachedOnly:
            scheduleDirectoryIndexWarmup(for: root)
            return .pendingWarmup
        case .synchronousFull:
            if let warmMatch = directoryIndex(for: root, useCache: false)[normalizedTarget]?.sorted(by: preferredLocalURLOrder).first {
                return .match(warmMatch)
            }
            return .noMatch
        }
    }

    private static func normalizedLocalMatchName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func preferredLocalURLOrder(lhs: URL, rhs: URL) -> Bool {
        let fileManager = FileManager.default
        var lhsIsDirectory: ObjCBool = false
        var rhsIsDirectory: ObjCBool = false
        let lhsExists = fileManager.fileExists(atPath: lhs.path, isDirectory: &lhsIsDirectory)
        let rhsExists = fileManager.fileExists(atPath: rhs.path, isDirectory: &rhsIsDirectory)
        if lhsExists, rhsExists, lhsIsDirectory.boolValue != rhsIsDirectory.boolValue {
            return lhsIsDirectory.boolValue && !rhsIsDirectory.boolValue
        }
        return lhs.path < rhs.path
    }

    private static func cachedResolvedLocalFileURL(for key: String) -> URL? {
        LocalFileResolutionCache.lock.lock()
        defer { LocalFileResolutionCache.lock.unlock() }
        return LocalFileResolutionCache.resolvedURLs[key]
    }

    private static func cachedDirectoryIndex(for root: URL) -> [String: [URL]]? {
        LocalFileResolutionCache.lock.lock()
        defer { LocalFileResolutionCache.lock.unlock() }
        return LocalFileResolutionCache.directoryIndexes[root.standardizedFileURL.path]
    }

    private static func isCachedLocalFileMiss(for key: String) -> Bool {
        LocalFileResolutionCache.lock.lock()
        defer { LocalFileResolutionCache.lock.unlock() }
        return LocalFileResolutionCache.misses.contains(key)
    }

    private static func cacheResolvedLocalFileURL(_ url: URL?, for key: String) {
        LocalFileResolutionCache.lock.lock()
        defer { LocalFileResolutionCache.lock.unlock() }
        if let url {
            LocalFileResolutionCache.resolvedURLs[key] = url
            LocalFileResolutionCache.misses.remove(key)
        } else {
            LocalFileResolutionCache.resolvedURLs.removeValue(forKey: key)
            LocalFileResolutionCache.misses.insert(key)
        }
    }

    private static func directoryIndex(for root: URL, useCache: Bool) -> [String: [URL]] {
        let rootKey = root.standardizedFileURL.path
        if useCache {
            LocalFileResolutionCache.lock.lock()
            if let cached = LocalFileResolutionCache.directoryIndexes[rootKey] {
                LocalFileResolutionCache.lock.unlock()
                return cached
            }
            LocalFileResolutionCache.lock.unlock()
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]
        var index: [String: [URL]] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let child = enumerator?.nextObject() as? URL {
            let relativeDepth = child.pathComponents.count - root.pathComponents.count
            if relativeDepth > 3 {
                enumerator?.skipDescendants()
                continue
            }
            index[normalizedLocalMatchName(child.lastPathComponent), default: []].append(child)
        }

        LocalFileResolutionCache.lock.lock()
        LocalFileResolutionCache.directoryIndexes[rootKey] = index
        LocalFileResolutionCache.warmingRoots.remove(rootKey)
        LocalFileResolutionCache.lock.unlock()
        return index
    }

    private static func scheduleDirectoryIndexWarmup(for root: URL) {
        let rootKey = root.standardizedFileURL.path
        LocalFileResolutionCache.lock.lock()
        if LocalFileResolutionCache.directoryIndexes[rootKey] != nil ||
            LocalFileResolutionCache.warmingRoots.contains(rootKey) {
            LocalFileResolutionCache.lock.unlock()
            return
        }
        LocalFileResolutionCache.warmingRoots.insert(rootKey)
        LocalFileResolutionCache.lock.unlock()

        directoryIndexWarmupQueue.async {
            _ = directoryIndex(for: root, useCache: false)
        }
    }

    private static func bulletParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        style.paragraphSpacing = 10
        style.headIndent = 18
        return style
    }
}
