import Foundation
import ImageIO

struct CompressionProcessedItem: Equatable {
    let sourcePath: String
    let outputPath: String
    let sourceBytes: Int64
    let outputBytes: Int64
    let savedBytes: Int64
    let savedRatio: Double
    let tool: String
}

struct CompressionSkippedItem: Equatable {
    let path: String
    let reason: String
}

struct CompressionReport: Equatable {
    let selectedItemCount: Int
    let expandedFileCount: Int
    let missingRoots: [String]
    let processed: [CompressionProcessedItem]
    let skipped: [CompressionSkippedItem]
    let outputDirectory: String
    let toolBreakdown: [String: Int]

    var totalSourceBytes: Int64 {
        processed.reduce(0) { $0 + $1.sourceBytes }
    }

    var totalOutputBytes: Int64 {
        processed.reduce(0) { $0 + $1.outputBytes }
    }

    var savedBytes: Int64 {
        max(totalSourceBytes - totalOutputBytes, 0)
    }

    var savedRatio: Double {
        guard totalSourceBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(totalSourceBytes)
    }
}

enum CompressionRuntimeSupport {
    private struct ImageOutputPlan {
        let format: String
        let fileExtension: String
    }

    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "webp", "tif", "tiff", "bmp"
    ]
    private static let imageCompressMaxDimension = 2560
    private static let imageCompressQuality = "72"

    static func run(
        filePaths: [String],
        fileManager: FileManager = .default,
        diagnosticsLogger: DiagnosticsLogger = .shared
    ) -> CompressionReport {
        let roots = resolveSelectionRoots(from: filePaths, fileManager: fileManager)
        let expandedFiles = expandSelectionFiles(roots.existingRoots, fileManager: fileManager)
        let selectionParent = selectionParentDirectory(for: roots.existingRoots)

        var outputDirectoryURL: URL?
        var processed: [CompressionProcessedItem] = []
        var skipped: [CompressionSkippedItem] = []
        var toolBreakdown = ["image_compress": 0, "pdf_compress": 0]

        diagnosticsLogger.log(
            "compress.runtime",
            "selected=\(roots.existingRoots.count) expanded=\(expandedFiles.count) missing=\(roots.missingRoots.count)"
        )

        for fileURL in expandedFiles {
            if isSupportedImage(url: fileURL) {
                if outputDirectoryURL == nil {
                    outputDirectoryURL = createOutputDirectory(parent: selectionParent, fileManager: fileManager)
                }
                guard let outputDirectoryURL else { continue }
                let outputPlan = imageOutputPlan(for: fileURL)
                let outputURL = relativeOutputPath(
                    for: fileURL,
                    outputDirectory: outputDirectoryURL,
                    selectionParent: selectionParent,
                    outputExtension: outputPlan.fileExtension
                )
                do {
                    let item = try compressImageFile(
                        source: fileURL,
                        outputURL: outputURL,
                        outputPlan: outputPlan,
                        fileManager: fileManager
                    )
                    processed.append(item)
                    toolBreakdown["image_compress"] = (toolBreakdown["image_compress"] ?? 0) + 1
                    diagnosticsLogger.log(
                        "compress.runtime",
                        "compressed source=\(fileURL.path) output=\(outputURL.path) saved=\(item.savedBytes)"
                    )
                } catch {
                    skipped.append(.init(path: fileURL.path, reason: "image_compress_failed:\(error.localizedDescription)"))
                    diagnosticsLogger.log(
                        "compress.runtime",
                        "compress_failed source=\(fileURL.path) error=\(error.localizedDescription)"
                    )
                }
                continue
            }

            if isPDF(url: fileURL) {
                skipped.append(.init(path: fileURL.path, reason: "pdf_compress_not_implemented"))
                continue
            }

            skipped.append(.init(path: fileURL.path, reason: "unsupported_type"))
        }

        return CompressionReport(
            selectedItemCount: roots.existingRoots.count,
            expandedFileCount: expandedFiles.count,
            missingRoots: roots.missingRoots.map(\.path),
            processed: processed,
            skipped: skipped,
            outputDirectory: outputDirectoryURL?.path ?? "",
            toolBreakdown: toolBreakdown
        )
    }

    static func summary(for report: CompressionReport, languageCode: String) -> String {
        if report.processed.isEmpty {
            if report.skipped.contains(where: { $0.reason == "pdf_compress_not_implemented" }) {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "已分析 %d 个选中项，展开后共 %d 个文件。当前成功压缩 0 个文件；图片以外的 PDF 压缩还没补齐，其余不支持的文件已跳过。",
                    en: "Analyzed %d selected item(s) and expanded them into %d file(s). No files were compressed successfully. PDF compression is not ready yet, and the remaining unsupported files were skipped.",
                    report.selectedItemCount,
                    report.expandedFileCount
                )
            }

            if !report.skipped.isEmpty {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "已分析 %d 个选中项，展开后共 %d 个文件。当前没有可压缩的文件，已跳过不支持的类型。",
                    en: "Analyzed %d selected item(s) and expanded them into %d file(s). No compressible files were found, so unsupported types were skipped.",
                    report.selectedItemCount,
                    report.expandedFileCount
                )
            }

            return localized(
                zhHans: "没有检测到可处理的文件。",
                en: "No processable files were detected.",
                languageCode: languageCode
            )
        }

        var summary = L10n.format(
            languageCode: languageCode,
            zhHans: "已分析 %d 个选中项，展开后共 %d 个文件，成功压缩 %d 个文件，体积从 %@ 降到 %@，减少 %d%%。",
            en: "Analyzed %d selected item(s) and expanded them into %d file(s). Successfully compressed %d file(s), reducing the size from %@ to %@ for a %d%% reduction.",
            report.selectedItemCount,
            report.expandedFileCount,
            report.processed.count,
            humanBytes(report.totalSourceBytes),
            humanBytes(report.totalOutputBytes),
            Int((report.savedRatio * 100).rounded())
        )

        if !report.skipped.isEmpty {
            summary += L10n.format(
                languageCode: languageCode,
                zhHans: " 另有 %d 个文件已跳过。",
                en: " %d additional file(s) were skipped.",
                report.skipped.count
            )
        }

        if !report.outputDirectory.isEmpty {
            let folderName = URL(fileURLWithPath: report.outputDirectory).lastPathComponent
            summary += L10n.format(
                languageCode: languageCode,
                zhHans: " 输出目录：%@。",
                en: " Output folder: %@.",
                folderName
            )
        }

        return summary
    }

    static func cards(for report: CompressionReport, languageCode: String) -> [SkillResultCard] {
        guard !report.outputDirectory.isEmpty else { return [] }
        let folderName = URL(fileURLWithPath: report.outputDirectory).lastPathComponent
        return [
            SkillResultCard(
                id: "compressed_output_dir",
                kind: "output_directory",
                title: folderName,
                badges: [localized(zhHans: "输出目录", en: "Output Folder", languageCode: languageCode)],
                subtitle: report.outputDirectory,
                description: localized(
                    zhHans: "打开压缩后的文件目录",
                    en: "Open the folder containing the compressed files",
                    languageCode: languageCode
                ),
                action: SkillResultAction(
                    type: .openFile,
                    label: localized(zhHans: "打开目录", en: "Open Folder", languageCode: languageCode),
                    value: report.outputDirectory
                ),
                priority: .primary,
                isOfficial: nil
            )
        ]
    }

    private static func resolveSelectionRoots(
        from filePaths: [String],
        fileManager: FileManager
    ) -> (existingRoots: [URL], missingRoots: [URL]) {
        var existingRoots: [URL] = []
        var missingRoots: [URL] = []
        var seen: Set<String> = []

        for rawPath in filePaths.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            if fileManager.fileExists(atPath: url.path) {
                existingRoots.append(url)
            } else {
                missingRoots.append(url)
            }
        }

        return (existingRoots, missingRoots)
    }

    private static func expandSelectionFiles(_ roots: [URL], fileManager: FileManager) -> [URL] {
        var files: [URL] = []
        var seen: Set<String> = []

        for root in roots {
            if isDirectory(root, fileManager: fileManager) {
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                while let item = enumerator?.nextObject() as? URL {
                    guard !seen.contains(item.path),
                          fileManager.fileExists(atPath: item.path),
                          !isDirectory(item, fileManager: fileManager) else {
                        continue
                    }
                    seen.insert(item.path)
                    files.append(item.standardizedFileURL)
                }
            } else {
                guard seen.insert(root.path).inserted else { continue }
                files.append(root.standardizedFileURL)
            }
        }

        return files
    }

    private static func selectionParentDirectory(for roots: [URL]) -> URL {
        guard !roots.isEmpty else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }

        let parents = roots.map { $0.deletingLastPathComponent().path }
        let common = parents.dropFirst().reduce(parents[0]) { partial, next in
            commonPath(partial, next)
        }

        return URL(fileURLWithPath: common, isDirectory: true)
    }

    private static func commonPath(_ lhs: String, _ rhs: String) -> String {
        let lhsParts = URL(fileURLWithPath: lhs).pathComponents
        let rhsParts = URL(fileURLWithPath: rhs).pathComponents
        var shared: [String] = []
        for (left, right) in zip(lhsParts, rhsParts) where left == right {
            shared.append(left)
        }
        if shared.isEmpty { return "/" }
        return NSString.path(withComponents: shared)
    }

    private static func createOutputDirectory(parent: URL, fileManager: FileManager) -> URL {
        let base = parent.appendingPathComponent("NexHub Compressed", isDirectory: true)
        if !fileManager.fileExists(atPath: base.path) {
            try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let suffixed = parent.appendingPathComponent("NexHub Compressed \(formatter.string(from: Date()))", isDirectory: true)
        try? fileManager.createDirectory(at: suffixed, withIntermediateDirectories: true)
        return suffixed
    }

    private static func relativeOutputPath(
        for source: URL,
        outputDirectory: URL,
        selectionParent: URL,
        outputExtension: String
    ) -> URL {
        let relativeParent: String
        if source.path.hasPrefix(selectionParent.path + "/") {
            let relative = String(source.deletingLastPathComponent().path.dropFirst(selectionParent.path.count))
            relativeParent = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            relativeParent = ""
        }

        let folder = relativeParent.isEmpty
            ? outputDirectory
            : outputDirectory.appendingPathComponent(relativeParent, isDirectory: true)
        return folder.appendingPathComponent("\(safeOutputStem(source.deletingPathExtension().lastPathComponent)).\(outputExtension)")
    }

    private static func compressImageFile(
        source: URL,
        outputURL: URL,
        outputPlan: ImageOutputPlan,
        fileManager: FileManager
    ) throws -> CompressionProcessedItem {
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if outputPlan.format == "png",
           let pixelSize = imagePixelSize(for: source),
           max(pixelSize.width, pixelSize.height) <= CGFloat(imageCompressMaxDimension) {
            try? fileManager.removeItem(at: outputURL)
            try fileManager.copyItem(at: source, to: outputURL)
            let sourceBytes = fileSize(at: source, fileManager: fileManager)
            let outputBytes = fileSize(at: outputURL, fileManager: fileManager)
            return CompressionProcessedItem(
                sourcePath: source.path,
                outputPath: outputURL.path,
                sourceBytes: sourceBytes,
                outputBytes: outputBytes,
                savedBytes: max(sourceBytes - outputBytes, 0),
                savedRatio: sourceBytes > 0 ? Double(max(sourceBytes - outputBytes, 0)) / Double(sourceBytes) : 0,
                tool: "image_compress"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        var arguments = [
            "-s", "format", outputPlan.format,
            "--resampleHeightWidthMax", String(imageCompressMaxDimension),
            source.path,
            "--out", outputURL.path
        ]
        if outputPlan.format == "jpeg" {
            arguments.insert(contentsOf: ["-s", "formatOptions", imageCompressQuality], at: 2)
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: outputURL.path) else {
            let detail = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "CompressionRuntimeSupport",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail ?? "sips_failed"]
            )
        }

        let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        var outputAttributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        let sourceBytes = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
        var outputBytes = (outputAttributes[.size] as? NSNumber)?.int64Value ?? 0

        if outputBytes > sourceBytes {
            try? fileManager.removeItem(at: outputURL)
            try fileManager.copyItem(at: source, to: outputURL)
            outputAttributes = try fileManager.attributesOfItem(atPath: outputURL.path)
            outputBytes = (outputAttributes[.size] as? NSNumber)?.int64Value ?? sourceBytes
        }

        let savedBytes = max(sourceBytes - outputBytes, 0)
        let savedRatio = sourceBytes > 0 ? Double(savedBytes) / Double(sourceBytes) : 0

        return CompressionProcessedItem(
            sourcePath: source.path,
            outputPath: outputURL.path,
            sourceBytes: sourceBytes,
            outputBytes: outputBytes,
            savedBytes: savedBytes,
            savedRatio: savedRatio,
            tool: "image_compress"
        )
    }

    private static func imageOutputPlan(for source: URL) -> ImageOutputPlan {
        let ext = source.pathExtension.lowercased()
        switch ext {
        case "png":
            return .init(format: "png", fileExtension: "png")
        case "jpg", "jpeg":
            return .init(format: "jpeg", fileExtension: ext)
        default:
            return .init(format: "jpeg", fileExtension: "jpg")
        }
    }

    private static func imagePixelSize(for source: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func isSupportedImage(url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isPDF(url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    private static func safeOutputStem(_ stem: String) -> String {
        let cleaned = stem.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-._ "))
        return trimmed.isEmpty ? "compressed" : trimmed
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }
}
