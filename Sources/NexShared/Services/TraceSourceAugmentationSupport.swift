import Foundation

enum TraceSourceAugmentationSupport {
    private enum Provider: Equatable {
        case hackerNewsSearch
        case stackOverflowSearch
        case devToTag(String)
        case lobstersTag(String)
    }

    private static let generalTechKeywords: [String] = [
        " api ", " sdk ", " cli ", " mcp ", " llm ", " ai ", " agent ", " open source ", " github ",
        " repo ", " repository ", " library ", " framework ", " package ", " dependency ", " runtime ",
        " compiler ", " deployment ", " docker ", " kubernetes ", " database ", " sql ", " postgres ",
        " redis ", " react ", " next.js ", " nextjs ", " node ", " npm ", " pnpm ", " yarn ", " swift ",
        " rust ", " python ", " golang ", " java ", " typescript ", " javascript ", " docs ", " documentation ",
        " changelog ", " release notes ", " 模型 ", " 文档 ", " 接口 ", " 参数 ", " 代码 ", " 仓库 ", " 开源 ",
        " 部署 ", " 编译 ", " 框架 ", " 依赖 ", " 数据库 ", " 工具链 ", " 开发者 "
    ]

    private static let stackOverflowKeywords: [String] = [
        " error ", " bug ", " issue ", " exception ", " stack trace ", " traceback ", " warning ",
        " undefined ", " cannot ", " failed ", " install ", " compile ", " build ", " configure ",
        "怎么", "如何", "报错", "异常", "失败", "无法", "编译", "安装", "配置", "调用"
    ]

    private static let communityTagMap: [(needle: String, tag: String)] = [
        ("mcp", "ai"),
        ("llm", "ai"),
        ("agent", "ai"),
        ("openai", "ai"),
        ("anthropic", "ai"),
        ("huggingface", "ai"),
        ("swift", "swift"),
        ("rust", "rust"),
        ("python", "python"),
        ("typescript", "typescript"),
        ("javascript", "javascript"),
        ("react", "react"),
        ("nextjs", "nextjs"),
        ("next.js", "nextjs"),
        ("node", "nodejs"),
        ("nodejs", "nodejs"),
        ("docker", "docker"),
        ("kubernetes", "kubernetes"),
        ("postgres", "postgres"),
        ("sql", "sql"),
        ("vim", "vim"),
        ("linux", "linux")
    ]

    static func shouldUseOpenCLI(sourceText: String, plan: TracePlanDescriptor) -> Bool {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1600 else { return false }
        guard explicitURL(in: trimmed) == nil else { return false }

        if plan.entityType == "repo" || plan.entityType == "model" {
            return true
        }

        switch plan.intent.type {
        case "documentation", "model_lookup", "feature_lookup":
            return true
        case "official_source", "product_lookup":
            return looksTechnical(text: trimmed) || hasCodeLikeToken(in: trimmed)
        default:
            return false
        }
    }

    static func selectedProviders(sourceText: String, plan: TracePlanDescriptor) -> [String] {
        providerDescriptors(sourceText: sourceText, plan: plan).map(providerName)
    }

    static func searchAdditionalSources(
        sourceText: String,
        plan: TracePlanDescriptor,
        diagnosticsLogger: DiagnosticsLogger? = nil
    ) async -> [SourceRecord] {
        guard shouldUseOpenCLI(sourceText: sourceText, plan: plan) else { return [] }
        guard let binaryURL = resolveOpenCLIBinaryURL() else { return [] }

        let providers = providerDescriptors(sourceText: sourceText, plan: plan)
        guard !providers.isEmpty else { return [] }

        let query = communitySearchQuery(sourceText: sourceText, plan: plan)
        diagnosticsLogger?.log(
            "trace.opencli",
            "eligible=true providers=\(providers.map(providerName).joined(separator: ",")) query=\(query)"
        )

        var collected: [SourceRecord] = []
        await withTaskGroup(of: [SourceRecord].self) { group in
            for provider in providers {
                group.addTask {
                    await fetchSources(
                        provider: provider,
                        binaryURL: binaryURL,
                        query: query
                    )
                }
            }

            for await records in group {
                collected.append(contentsOf: records)
            }
        }

        var deduped: [SourceRecord] = []
        var seenURLs: Set<String> = []
        for record in collected {
            let key = record.url.lowercased()
            guard seenURLs.insert(key).inserted else { continue }
            deduped.append(record)
        }

        return Array(deduped.prefix(6))
    }

    private static func providerDescriptors(sourceText: String, plan: TracePlanDescriptor) -> [Provider] {
        guard shouldUseOpenCLI(sourceText: sourceText, plan: plan) else { return [] }

        var providers: [Provider] = [.hackerNewsSearch]
        let lowered = normalizedText(sourceText)

        if shouldUseStackOverflow(sourceText: lowered, plan: plan) {
            providers.append(.stackOverflowSearch)
        }

        if let tag = mappedCommunityTag(from: lowered) {
            providers.append(.devToTag(tag))
            providers.append(.lobstersTag(tag))
        }

        return providers
    }

    private static func looksTechnical(text: String) -> Bool {
        let lowered = normalizedText(text)
        if generalTechKeywords.contains(where: lowered.contains) {
            return true
        }

        let hasLatinIdentifier = lowered.range(of: #"\b[a-z][a-z0-9.+_-]{2,24}\b"#, options: .regularExpression) != nil
        let hasChineseTechSignal = ["文档", "接口", "模型", "开源", "仓库", "部署", "代码"].contains(where: lowered.contains)
        return hasLatinIdentifier && hasChineseTechSignal
    }

    private static func hasCodeLikeToken(in text: String) -> Bool {
        let lowered = normalizedText(text)
        return lowered.range(of: #"`[^`]+`|[A-Za-z_][A-Za-z0-9_]*\(|/[A-Za-z0-9._/-]+|[A-Za-z0-9._-]+\.[A-Za-z]{2,6}"#, options: .regularExpression) != nil
    }

    private static func shouldUseStackOverflow(sourceText: String, plan: TracePlanDescriptor) -> Bool {
        if plan.intent.type == "documentation" || plan.intent.type == "feature_lookup" {
            return true
        }
        return stackOverflowKeywords.contains(where: sourceText.contains)
    }

    private static func mappedCommunityTag(from loweredText: String) -> String? {
        for entry in communityTagMap where loweredText.contains(entry.needle) {
            return entry.tag
        }
        return nil
    }

    private static func communitySearchQuery(sourceText: String, plan: TracePlanDescriptor) -> String {
        let trimmedEntity = plan.primaryEntityName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEntity.isEmpty, trimmedEntity.count <= 80 {
            if plan.intent.type == "documentation" {
                return "\(trimmedEntity) API"
            }
            return trimmedEntity
        }

        let compact = sourceText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 96 {
            return compact
        }

        let index = compact.index(compact.startIndex, offsetBy: 96)
        return String(compact[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fetchSources(
        provider: Provider,
        binaryURL: URL,
        query: String
    ) async -> [SourceRecord] {
        let command = commandArguments(for: provider, query: query)
        guard let output = await runOpenCLI(binaryURL: binaryURL, arguments: command, timeout: 2.8) else {
            return []
        }
        return parseRecords(from: output, provider: provider)
    }

    private static func commandArguments(for provider: Provider, query: String) -> [String] {
        switch provider {
        case .hackerNewsSearch:
            return ["hackernews", "search", query, "--limit", "2", "--format", "json"]
        case .stackOverflowSearch:
            return ["stackoverflow", "search", query, "--limit", "2", "--format", "json"]
        case .devToTag(let tag):
            return ["devto", "tag", tag, "--limit", "2", "--format", "json"]
        case .lobstersTag(let tag):
            return ["lobsters", "tag", tag, "--limit", "2", "--format", "json"]
        }
    }

    private static func parseRecords(from output: String, provider: Provider) -> [SourceRecord] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return SourceRecord(
                title: title,
                url: url,
                snippet: snippet(for: item, provider: provider),
                publishedAt: nil,
                sourceType: sourceType(for: provider),
                isOfficial: false
            )
        }
    }

    private static func snippet(for item: [String: Any], provider: Provider) -> String {
        func intValue(_ key: String) -> String? {
            if let number = item[key] as? NSNumber {
                return number.stringValue
            }
            if let value = item[key] as? Int {
                return String(value)
            }
            return nil
        }

        let author = (item["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (item["tags"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch provider {
        case .hackerNewsSearch:
            return [
                author.map { "HN author: \($0)" },
                intValue("score").map { "score \($0)" },
                intValue("comments").map { "\($0) comments" }
            ].compactMap { $0 }.joined(separator: " • ")
        case .stackOverflowSearch:
            return [
                intValue("answers").map { "\($0) answers" },
                intValue("score").map { "score \($0)" }
            ].compactMap { $0 }.joined(separator: " • ")
        case .devToTag:
            return [
                author.map { "Dev.to author: \($0)" },
                tags.flatMap { $0.isEmpty ? nil : "tags: \($0)" },
                intValue("reactions").map { "\($0) reactions" }
            ].compactMap { $0 }.joined(separator: " • ")
        case .lobstersTag:
            return [
                author.map { "Lobsters author: \($0)" },
                tags.flatMap { $0.isEmpty ? nil : "tags: \($0)" },
                intValue("score").map { "score \($0)" },
                intValue("comments").map { "\($0) comments" }
            ].compactMap { $0 }.joined(separator: " • ")
        }
    }

    private static func sourceType(for provider: Provider) -> String {
        switch provider {
        case .hackerNewsSearch:
            return "community_news"
        case .stackOverflowSearch:
            return "community_qna"
        case .devToTag:
            return "community_article"
        case .lobstersTag:
            return "community_discussion"
        }
    }

    private static func providerName(for provider: Provider) -> String {
        switch provider {
        case .hackerNewsSearch:
            return "hackernews_search"
        case .stackOverflowSearch:
            return "stackoverflow_search"
        case .devToTag(let tag):
            return "devto_tag:\(tag)"
        case .lobstersTag(let tag):
            return "lobsters_tag:\(tag)"
        }
    }

    private static func normalizedText(_ text: String) -> String {
        " " + text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "
    }

    private static func explicitURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first
    }

    private static func resolveOpenCLIBinaryURL() -> URL? {
        let fileManager = FileManager.default

        for rawPath in openCLICandidatePaths() where fileManager.isExecutableFile(atPath: rawPath) {
            return URL(fileURLWithPath: rawPath)
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent("opencli-rs")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func openCLICandidatePaths() -> [String] {
        var paths: [String] = []

        if let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(
                appSupportRoot
                    .appendingPathComponent(AppBrand.supportDirectoryName, isDirectory: true)
                    .appendingPathComponent("Tools", isDirectory: true)
                    .appendingPathComponent("opencli-rs", isDirectory: false)
                    .path
            )
        }

        if let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("Tooling", isDirectory: true)
            .appendingPathComponent("opencli-rs", isDirectory: false) {
            paths.append(bundledURL.path)
        }

        paths.append(contentsOf: [
            "/opt/homebrew/bin/opencli-rs",
            "/usr/local/bin/opencli-rs"
        ])

        return paths
    }

    private static func runOpenCLI(
        binaryURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 150_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
