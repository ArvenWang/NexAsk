import Foundation

final class SkillPresentationCoordinator {
    private struct ToolbarExposureSession {
        let selectionSignature: String
        let selectionType: String
        let bundleID: String?
        let contentCategory: String
        let primarySkillIDs: [String]
        let secondarySkillIDs: [String]
        var hasRecordedAction: Bool
    }

    private let actionRegistry: ActionRegistry
    private let contextRouter: ContextRouter
    private let usageLearningStore: UsageLearningStore
    private let routeDiagnosticsStore: RouteDiagnosticsStore
    private let textArtifactBuilder: TextArtifactBuilder
    private let fileArtifactBuilder: FileArtifactBuilder
    private let imageArtifactBuilder: ImageArtifactBuilder

    private var currentToolbarExposure: ToolbarExposureSession?

    init(
        actionRegistry: ActionRegistry = .shared,
        contextRouter: ContextRouter = ContextRouter(),
        usageLearningStore: UsageLearningStore = .shared,
        routeDiagnosticsStore: RouteDiagnosticsStore = .shared,
        textArtifactBuilder: TextArtifactBuilder = TextArtifactBuilder(),
        fileArtifactBuilder: FileArtifactBuilder = FileArtifactBuilder(),
        imageArtifactBuilder: ImageArtifactBuilder = ImageArtifactBuilder()
    ) {
        self.actionRegistry = actionRegistry
        self.contextRouter = contextRouter
        self.usageLearningStore = usageLearningStore
        self.routeDiagnosticsStore = routeDiagnosticsStore
        self.textArtifactBuilder = textArtifactBuilder
        self.fileArtifactBuilder = fileArtifactBuilder
        self.imageArtifactBuilder = imageArtifactBuilder
    }

    func prepareToolbarLayout(
        textSnapshot: SelectionSnapshot?,
        fileSnapshot: FileSelectionSnapshot?,
        imageSnapshot: ImageSelectionSnapshot?,
        settings: AppSettings
    ) -> ToolbarSlotLayoutState {
        let enabledDefinitions = actionRegistry.enabledDefinitions(settings: settings)
        guard !enabledDefinitions.isEmpty else {
            finalizeToolbarExposureIfNeeded(recordDismissal: false)
            routeDiagnosticsStore.update(nil)
            return makeToolbarSlotLayout(
                textSnapshot: textSnapshot,
                fileSnapshot: fileSnapshot,
                imageSnapshot: imageSnapshot,
                primarySkillIDs: [],
                secondarySkillIDs: []
            )
        }

        guard textSnapshot != nil || fileSnapshot != nil || imageSnapshot != nil else {
            finalizeToolbarExposureIfNeeded(recordDismissal: true)
            routeDiagnosticsStore.update(nil)
            let primary = actionRegistry.defaultPrimarySkillIDs(settings: settings)
            let secondary = actionRegistry.defaultSecondarySkillIDs(settings: settings, excluding: primary)
            return makeToolbarSlotLayout(
                textSnapshot: nil,
                fileSnapshot: nil,
                imageSnapshot: nil,
                primarySkillIDs: primary,
                secondarySkillIDs: secondary
            )
        }

        guard let plan = makeExecutionPlan(
            textSnapshot: textSnapshot,
            fileSnapshot: fileSnapshot,
            imageSnapshot: imageSnapshot,
            enabledDefinitions: enabledDefinitions
        ) else {
            return .empty
        }

        routeDiagnosticsStore.update(plan.makeRouteDiagnosticsSnapshot(actionRegistry: actionRegistry))

        let layout = makeToolbarSlotLayout(
            textSnapshot: textSnapshot,
            fileSnapshot: fileSnapshot,
            imageSnapshot: imageSnapshot,
            primarySkillIDs: plan.primarySkillIDs,
            secondarySkillIDs: plan.secondarySkillIDs
        )

        if let textSnapshot {
            recordToolbarExposureIfNeeded(
                textSnapshot: textSnapshot,
                contentCategory: plan.contentCategory,
                primarySkillIDs: plan.primarySkillIDs,
                secondarySkillIDs: plan.secondarySkillIDs
            )
        } else if let fileSnapshot {
            recordToolbarExposureIfNeeded(
                fileSnapshot: fileSnapshot,
                contentCategory: plan.contentCategory,
                primarySkillIDs: plan.primarySkillIDs,
                secondarySkillIDs: plan.secondarySkillIDs
            )
        } else if let imageSnapshot {
            recordToolbarExposureIfNeeded(
                imageSnapshot: imageSnapshot,
                contentCategory: plan.contentCategory,
                primarySkillIDs: plan.primarySkillIDs,
                secondarySkillIDs: plan.secondarySkillIDs
            )
        }

        return layout
    }

    func clearRouteDiagnostics() {
        routeDiagnosticsStore.update(nil)
    }

    func finalizeToolbarExposureIfNeeded(recordDismissal: Bool) {
        guard let exposure = currentToolbarExposure else { return }
        currentToolbarExposure = nil
        guard recordDismissal, !exposure.hasRecordedAction else { return }
        usageLearningStore.recordDismissedExposure(
            skillIDs: exposure.primarySkillIDs,
            moreSkillIDs: exposure.secondarySkillIDs,
            selectionType: exposure.selectionType,
            bundleID: exposure.bundleID,
            contentCategory: exposure.contentCategory
        )
    }

    func recordSkillInvocationIfNeeded(skillID: String) {
        guard var exposure = currentToolbarExposure else { return }
        let source: ToolbarSkillSource
        if exposure.primarySkillIDs.contains(skillID) {
            source = .primary
        } else if exposure.secondarySkillIDs.contains(skillID) {
            source = .more
        } else {
            return
        }

        usageLearningStore.recordAction(
            skillID: skillID,
            source: source,
            selectionType: exposure.selectionType,
            bundleID: exposure.bundleID,
            contentCategory: exposure.contentCategory
        )
        exposure.hasRecordedAction = true
        currentToolbarExposure = exposure
    }

    private func candidateDefinitions(for context: ActivationContext, from definitions: [SkillDefinition]) -> [SkillDefinition] {
        let contextSupported = definitions.filter { definition in
            definition.supportedContexts.contains(context.source)
        }
        guard !contextSupported.isEmpty else {
            return definitions
        }
        let filtered = contextSupported.filter { definition in
            definition.supportedContexts.contains(context.source)
                && definition.preferredContentTypes.contains(context.contentType)
        }
        return filtered.isEmpty ? contextSupported : filtered
    }

    private func makeExecutionPlan(
        textSnapshot: SelectionSnapshot?,
        fileSnapshot: FileSelectionSnapshot?,
        imageSnapshot: ImageSelectionSnapshot?,
        enabledDefinitions: [SkillDefinition]
    ) -> SkillExecutionPlan? {
        let artifact: ActivationArtifact
        if let fileSnapshot {
            artifact = .file(fileArtifactBuilder.build(from: fileSnapshot))
        } else if let imageSnapshot {
            artifact = .image(imageArtifactBuilder.build(from: imageSnapshot))
        } else if let textSnapshot {
            artifact = .text(textArtifactBuilder.build(from: textSnapshot))
        } else {
            return nil
        }

        let context = artifact.activationContext
        let candidates = candidateDefinitions(for: context, from: enabledDefinitions)
        let route = contextRouter.route(
            context: context,
            sourceInteractionContext: artifact.sourceInteractionContext,
            candidates: candidates
        )
        return SkillExecutionPlan(
            activationContext: context,
            sourceInteractionContext: artifact.sourceInteractionContext,
            selectionPreview: routeSelectionPreview(
                textSnapshot: textSnapshot,
                fileSnapshot: fileSnapshot,
                imageSnapshot: imageSnapshot
            ),
            contentCategory: route.contentCategory,
            confidence: route.confidence,
            primarySkillIDs: route.primarySkillIDs,
            secondarySkillIDs: route.secondarySkillIDs,
            rankedIntents: route.likelyIntents,
            timestamp: Date()
        )
    }

    private func makeToolbarSlotLayout(
        textSnapshot: SelectionSnapshot?,
        fileSnapshot: FileSelectionSnapshot?,
        imageSnapshot: ImageSelectionSnapshot?,
        primarySkillIDs: [String],
        secondarySkillIDs: [String]
    ) -> ToolbarSlotLayoutState {
        ToolbarSlotLayoutState(
            recognitionSlot: fileSnapshot != nil
                ? .fileCount(count: fileSnapshot?.fileURLs.count ?? 0)
                : (imageSnapshot != nil
                    ? .screenshotSize(
                        width: imageSnapshot?.pixelWidth ?? 0,
                        height: imageSnapshot?.pixelHeight ?? 0
                    )
                    : .textCount(count: textSnapshot?.text.count ?? 0)),
            skillSlots: Array(primarySkillIDs.prefix(3)).enumerated().map { index, skillID in
                SkillSlotState(slotIndex: index, skillID: skillID)
            },
            moreSlot: MoreSlotState(skillIDs: secondarySkillIDs)
        )
    }

    private func recordToolbarExposureIfNeeded(
        textSnapshot: SelectionSnapshot,
        contentCategory: String,
        primarySkillIDs: [String],
        secondarySkillIDs: [String]
    ) {
        let selectionType = ActivationContentType.text.rawValue
        let signature = toolbarExposureSignature(
            text: textSnapshot.text,
            bundleID: textSnapshot.sourceBundleID,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs
        )

        if let currentToolbarExposure, currentToolbarExposure.selectionSignature == signature {
            return
        }

        finalizeToolbarExposureIfNeeded(recordDismissal: true)
        usageLearningStore.recordImpression(
            skillIDs: primarySkillIDs,
            moreSkillIDs: secondarySkillIDs,
            selectionType: selectionType,
            bundleID: textSnapshot.sourceBundleID,
            contentCategory: contentCategory
        )
        currentToolbarExposure = ToolbarExposureSession(
            selectionSignature: signature,
            selectionType: selectionType,
            bundleID: textSnapshot.sourceBundleID,
            contentCategory: contentCategory,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs,
            hasRecordedAction: false
        )
    }

    private func recordToolbarExposureIfNeeded(
        fileSnapshot: FileSelectionSnapshot,
        contentCategory: String,
        primarySkillIDs: [String],
        secondarySkillIDs: [String]
    ) {
        let selectionType = ActivationContentType.file.rawValue
        let signature = toolbarExposureSignature(
            filePaths: fileSnapshot.fileURLs.map(\.path),
            bundleID: fileSnapshot.sourceBundleID,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs
        )

        if let currentToolbarExposure, currentToolbarExposure.selectionSignature == signature {
            return
        }

        finalizeToolbarExposureIfNeeded(recordDismissal: true)
        usageLearningStore.recordImpression(
            skillIDs: primarySkillIDs,
            moreSkillIDs: secondarySkillIDs,
            selectionType: selectionType,
            bundleID: fileSnapshot.sourceBundleID,
            contentCategory: contentCategory
        )
        currentToolbarExposure = ToolbarExposureSession(
            selectionSignature: signature,
            selectionType: selectionType,
            bundleID: fileSnapshot.sourceBundleID,
            contentCategory: contentCategory,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs,
            hasRecordedAction: false
        )
    }

    private func recordToolbarExposureIfNeeded(
        imageSnapshot: ImageSelectionSnapshot,
        contentCategory: String,
        primarySkillIDs: [String],
        secondarySkillIDs: [String]
    ) {
        let selectionType = ActivationContentType.image.rawValue
        let signature = toolbarExposureSignature(
            filePaths: [imageSnapshot.imageURL.path],
            bundleID: imageSnapshot.sourceBundleID,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs
        )

        if let currentToolbarExposure, currentToolbarExposure.selectionSignature == signature {
            return
        }

        finalizeToolbarExposureIfNeeded(recordDismissal: true)
        usageLearningStore.recordImpression(
            skillIDs: primarySkillIDs,
            moreSkillIDs: secondarySkillIDs,
            selectionType: selectionType,
            bundleID: imageSnapshot.sourceBundleID,
            contentCategory: contentCategory
        )
        currentToolbarExposure = ToolbarExposureSession(
            selectionSignature: signature,
            selectionType: selectionType,
            bundleID: imageSnapshot.sourceBundleID,
            contentCategory: contentCategory,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs,
            hasRecordedAction: false
        )
    }

    private func toolbarExposureSignature(
        text: String,
        bundleID: String?,
        primarySkillIDs: [String],
        secondarySkillIDs: [String]
    ) -> String {
        [
            bundleID ?? "unknown",
            text,
            primarySkillIDs.joined(separator: ","),
            secondarySkillIDs.joined(separator: ",")
        ].joined(separator: "|")
    }

    private func toolbarExposureSignature(
        filePaths: [String],
        bundleID: String?,
        primarySkillIDs: [String],
        secondarySkillIDs: [String]
    ) -> String {
        [
            bundleID ?? "unknown",
            filePaths.joined(separator: "\n"),
            primarySkillIDs.joined(separator: ","),
            secondarySkillIDs.joined(separator: ",")
        ].joined(separator: "|")
    }

    private func routeSelectionPreview(
        textSnapshot: SelectionSnapshot?,
        fileSnapshot: FileSelectionSnapshot?,
        imageSnapshot: ImageSelectionSnapshot?
    ) -> String {
        if let textSnapshot {
            return routeSelectionPreview(from: textSnapshot.text)
        }
        if let imageSnapshot {
            return imageSnapshot.selectionPreviewText
        }
        let fileNames = fileSnapshot?.fileURLs.map(\.lastPathComponent).joined(separator: ", ") ?? ""
        if fileNames.count <= 80 {
            return fileNames
        }
        return String(fileNames.prefix(80)) + "..."
    }

    private func routeSelectionPreview(from text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= 80 {
            return normalized
        }
        return String(normalized.prefix(80)) + "..."
    }
}
