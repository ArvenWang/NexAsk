import Foundation

package actor AskInMemoryApprovalRouter: AskApprovalRouting {
    package static let shared = AskInMemoryApprovalRouter(persistToDisk: true)

    private struct Payload: Codable {
        let version: Int
        let approvals: [AskCapabilityApprovalRecord]
    }

    private var approvalsByID: [String: AskCapabilityApprovalRecord] = [:]
    private let persistToDisk: Bool
    private let approvalsFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    package init(
        fileManager: FileManager = .default,
        persistToDisk: Bool = false,
        rootDirectoryURL: URL? = nil
    ) {
        self.persistToDisk = persistToDisk
        let root = rootDirectoryURL ?? AskKernelPersistencePaths.askRoot(fileManager: fileManager)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.approvalsFileURL = root.appendingPathComponent("kernel_approvals.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        guard persistToDisk,
              let data = try? Data(contentsOf: approvalsFileURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return
        }
        approvalsByID = Dictionary(uniqueKeysWithValues: payload.approvals.map { ($0.approvalID, $0) })
    }

    package func createApprovalRequest(
        for request: AskCapabilityExecutionRequest,
        reason: String
    ) async -> AskCapabilityApprovalRecord {
        let approvalID = UUID().uuidString.lowercased()
        let record = AskCapabilityApprovalRecord(
            approvalID: approvalID,
            request: request,
            reason: reason,
            createdAt: Date()
        )
        approvalsByID[approvalID] = record
        persistApprovalsIfNeeded()
        return record
    }

    package func approvalRequest(id: String) async -> AskCapabilityApprovalRecord? {
        approvalsByID[id]
    }

    package func removeApprovalRequest(id: String) async -> AskCapabilityApprovalRecord? {
        let record = approvalsByID.removeValue(forKey: id)
        if record != nil {
            persistApprovalsIfNeeded()
        }
        return record
    }

    package func latestApprovalRequest(
        sessionID: String,
        capabilityID: AskCapabilityID? = nil
    ) async -> AskCapabilityApprovalRecord? {
        approvalsByID.values
            .filter { record in
                guard record.request.task.metadata["session_id"] == sessionID else {
                    return false
                }
                if let capabilityID {
                    return record.request.capability.id == capabilityID
                }
                return true
            }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    package func clearAll() async {
        approvalsByID.removeAll()
        persistApprovalsIfNeeded()
    }

    private func persistApprovalsIfNeeded() {
        guard persistToDisk else { return }
        let payload = Payload(
            version: 1,
            approvals: approvalsByID.values.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.approvalID < rhs.approvalID
                }
                return lhs.createdAt > rhs.createdAt
            }
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: approvalsFileURL, options: .atomic)
    }
}

package actor AskInMemoryTaskStore: AskTaskStoring {
    package static let shared = AskInMemoryTaskStore(persistToDisk: true)

    private struct Payload: Codable {
        let version: Int
        let tasks: [AskAgentTask]
    }

    private var tasksByID: [String: AskAgentTask] = [:]
    private let persistToDisk: Bool
    private let tasksFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    package init(
        fileManager: FileManager = .default,
        persistToDisk: Bool = false,
        rootDirectoryURL: URL? = nil
    ) {
        self.persistToDisk = persistToDisk
        let root = rootDirectoryURL ?? AskKernelPersistencePaths.askRoot(fileManager: fileManager)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.tasksFileURL = root.appendingPathComponent("kernel_tasks.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        guard persistToDisk,
              let data = try? Data(contentsOf: tasksFileURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return
        }
        tasksByID = Dictionary(uniqueKeysWithValues: payload.tasks.map { ($0.id, $0) })
    }

    package func save(_ task: AskAgentTask) async {
        tasksByID[task.id] = task
        persistTasksIfNeeded()
    }

    package func task(id: String) async -> AskAgentTask? {
        tasksByID[id]
    }

    package func tasks(for sessionID: String?) async -> [AskAgentTask] {
        tasksByID.values
            .filter { task in
                guard let sessionID else { return true }
                return task.metadata["session_id"] == sessionID
            }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    package func mark(
        taskID: String,
        status: AskTaskStatus,
        pendingApprovalID: String?,
        appendingArtifacts artifacts: [String],
        mergingMetadata metadata: AskInvocationMetadata
    ) async -> AskAgentTask? {
        guard let existing = tasksByID[taskID] else { return nil }
        let updated = existing.updated(
            status: status,
            pendingApprovalID: pendingApprovalID,
            appendingArtifacts: artifacts,
            mergingMetadata: metadata
        )
        tasksByID[taskID] = updated
        persistTasksIfNeeded()
        return updated
    }

    private func persistTasksIfNeeded() {
        guard persistToDisk else { return }
        let payload = Payload(
            version: 1,
            tasks: tasksByID.values.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: tasksFileURL, options: .atomic)
    }
}

package struct AskKernelDeliveredResultRecord: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package let taskID: String
    package let sessionID: String?
    package let automationJobID: String?
    package let capabilityID: AskCapabilityID
    package let status: AskCapabilityExecutionStatus
    package let summary: String
    package let artifacts: [AskCapabilityArtifact]
    package let metadata: AskInvocationMetadata
    package let deliveredAt: Date

    package init(
        id: String,
        taskID: String,
        sessionID: String?,
        automationJobID: String?,
        capabilityID: AskCapabilityID,
        status: AskCapabilityExecutionStatus,
        summary: String,
        artifacts: [AskCapabilityArtifact],
        metadata: AskInvocationMetadata,
        deliveredAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.sessionID = sessionID
        self.automationJobID = automationJobID
        self.capabilityID = capabilityID
        self.status = status
        self.summary = summary
        self.artifacts = artifacts
        self.metadata = metadata
        self.deliveredAt = deliveredAt
    }
}

package actor AskKernelResultStore {
    package static let shared = AskKernelResultStore(persistToDisk: true)

    private static let resultsDidChangeNotification = Notification.Name("nexhub.askKernel.resultsDidChange")

    private struct Payload: Codable {
        let version: Int
        let records: [AskKernelDeliveredResultRecord]
    }

    private let notificationCenter: NotificationCenter
    private let persistToDisk: Bool
    private let recordsFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var recordsByTaskID: [String: [AskKernelDeliveredResultRecord]] = [:]

    package init(
        notificationCenter: NotificationCenter = .default,
        fileManager: FileManager = .default,
        persistToDisk: Bool = false,
        rootDirectoryURL: URL? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.persistToDisk = persistToDisk
        let root = rootDirectoryURL ?? AskKernelPersistencePaths.askRoot(fileManager: fileManager)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.recordsFileURL = root.appendingPathComponent("kernel_results.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        guard persistToDisk,
              let data = try? Data(contentsOf: recordsFileURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return
        }
        recordsByTaskID = Dictionary(grouping: payload.records, by: \.taskID)
    }

    package func append(_ record: AskKernelDeliveredResultRecord) {
        recordsByTaskID[record.taskID, default: []].append(record)
        persistRecordsIfNeeded()
        notificationCenter.post(
            name: Self.resultsDidChangeNotification,
            object: nil,
            userInfo: [
                "task_id": record.taskID,
                "capability_id": record.capabilityID,
                "session_id": record.sessionID ?? ""
            ]
        )
    }

    package func records(taskID: String) -> [AskKernelDeliveredResultRecord] {
        recordsByTaskID[taskID, default: []]
            .sorted { $0.deliveredAt < $1.deliveredAt }
    }

    package func records(sessionID: String?, limit: Int = 40) -> [AskKernelDeliveredResultRecord] {
        recordsByTaskID.values
            .flatMap { $0 }
            .filter { record in
                guard let sessionID else { return true }
                return record.sessionID == sessionID
            }
            .sorted { $0.deliveredAt > $1.deliveredAt }
            .prefix(limit)
            .map { $0 }
    }

    package func records(workspaceRoot: String?, limit: Int = 40) -> [AskKernelDeliveredResultRecord] {
        recordsByTaskID.values
            .flatMap { $0 }
            .filter { record in
                guard let workspaceRoot else { return false }
                return record.metadata["workspace_root"] == workspaceRoot
            }
            .sorted { $0.deliveredAt > $1.deliveredAt }
            .prefix(limit)
            .map { $0 }
    }

    private func persistRecordsIfNeeded() {
        guard persistToDisk else { return }
        let payload = Payload(
            version: 1,
            records: recordsByTaskID.values
                .flatMap { $0 }
                .sorted { lhs, rhs in
                    if lhs.deliveredAt == rhs.deliveredAt {
                        return lhs.id < rhs.id
                    }
                    return lhs.deliveredAt > rhs.deliveredAt
                }
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: recordsFileURL, options: .atomic)
    }
}

package struct AskStoreBackedResultDelivery: AskResultDelivering {
    private let store: AskKernelResultStore

    package init(store: AskKernelResultStore = .shared) {
        self.store = store
    }

    package func deliver(
        result: AskCapabilityExecutionResult,
        for task: AskAgentTask,
        capabilityID: AskCapabilityID
    ) async {
        let record = AskKernelDeliveredResultRecord(
            id: UUID().uuidString.lowercased(),
            taskID: task.id,
            sessionID: task.metadata["session_id"],
            automationJobID: task.lineage.automationJobID,
            capabilityID: capabilityID,
            status: result.status,
            summary: result.summary,
            artifacts: result.artifacts,
            metadata: result.metadata,
            deliveredAt: Date()
        )
        await store.append(record)
    }
}

package struct AskStoreBackedMemoryFabric: AskMemoryFabricProviding {
    private let resultStore: AskKernelResultStore
    private let taskStore: AskTaskStoring

    package init(
        resultStore: AskKernelResultStore = .shared,
        taskStore: AskTaskStoring
    ) {
        self.resultStore = resultStore
        self.taskStore = taskStore
    }

    package func sessionSummary(sessionID: String?) async -> String? {
        let tasks = await taskStore.tasks(for: sessionID)
        let records = await resultStore.records(sessionID: sessionID, limit: 3)
        return summary(tasks: tasks, records: records, emptyFallback: nil)
    }

    package func workspaceSummary(rootPath: String?) async -> String? {
        let tasks = await taskStore.tasks(for: nil)
            .filter { task in
                guard let rootPath else { return false }
                return task.context.workspaceRootPath == rootPath || task.metadata["workspace_root"] == rootPath
            }
        let records = await resultStore.records(workspaceRoot: rootPath, limit: 3)
        return summary(tasks: tasks, records: records, emptyFallback: nil)
    }

    private func summary(
        tasks: [AskAgentTask],
        records: [AskKernelDeliveredResultRecord],
        emptyFallback: String?
    ) -> String? {
        guard !tasks.isEmpty || !records.isEmpty else { return emptyFallback }
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let childTasks = tasks.filter { $0.lineage.parentTaskID != nil }
        let latestTaskSummary = tasks.last.map { taskSummary($0, tasksByID: tasksByID) }
        let childTaskSummary = childTaskRollup(childTasks: childTasks)
        let resultSummary = records
            .prefix(2)
            .map { record in
                let shortSummary = clippedText(record.summary, limit: 72) ?? record.summary
                return "\(record.capabilityID) [\(record.status.rawValue)]: \(shortSummary)"
            }
            .joined(separator: " | ")
        let assistantDeliverySummary = assistantDeliverySummary(records: records)
        return [latestTaskSummary, childTaskSummary, assistantDeliverySummary, resultSummary]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " | ")
    }

    private func taskSummary(
        _ task: AskAgentTask,
        tasksByID: [String: AskAgentTask]
    ) -> String {
        let label = task.lineage.parentTaskID == nil ? "task" : "child_task"
        var parts = [
            "\(label) [\(task.status.rawValue)]: \(clippedText(task.title, limit: 56) ?? task.title)"
        ]
        if let parentTaskID = task.lineage.parentTaskID,
           let parentTitle = clippedText(tasksByID[parentTaskID]?.title, limit: 36) {
            parts.append("parent=\(parentTitle)")
        }
        if task.context.metadata["plan_mode_active"]?.lowercased() == "true" {
            parts.append("plan_mode")
        }
        if let planSummary = clippedText(task.context.metadata["plan_mode_summary"], limit: 48) {
            parts.append("plan=\(planSummary)")
        }
        if let permissionProfile = clippedText(task.context.metadata["workspace_permission_profile"], limit: 48) {
            parts.append("workspace_permission_profile=\(permissionProfile)")
        }
        if task.todoCount > 0 {
            parts.append("todo=\(task.todoProgressSummary)")
        }
        if task.context.metadata["workspace_write_granted"]?.lowercased() == "true" {
            parts.append("writes_granted")
        }
        if task.context.metadata["workspace_shell_granted"]?.lowercased() == "true" {
            parts.append("shell_granted")
        }
        if task.context.metadata["workspace_git_write_granted"]?.lowercased() == "true" {
            parts.append("git_write_granted")
        }
        if task.context.metadata["workspace_network_access_granted"]?.lowercased() == "true" {
            parts.append("network_granted")
        }
        if task.pendingApprovalID != nil {
            parts.append("approval=pending")
        }
        return parts.joined(separator: ", ")
    }

    private func childTaskRollup(childTasks: [AskAgentTask]) -> String? {
        guard !childTasks.isEmpty else { return nil }
        let openCount = childTasks.filter { task in
            switch task.status {
            case .completed, .failed, .cancelled:
                return false
            case .queued, .planning, .waitingApproval, .running, .blocked:
                return true
            }
        }.count
        var parts = ["subtasks=\(childTasks.count)"]
        if openCount > 0 {
            parts.append("open_subtasks=\(openCount)")
        }
        if let latestChildTask = childTasks.last {
            let latestTitle = clippedText(latestChildTask.title, limit: 48) ?? latestChildTask.title
            parts.append("latest_subtask=\(latestTitle) [\(latestChildTask.status.rawValue)]")
        }
        return parts.joined(separator: ", ")
    }

    private func assistantDeliverySummary(records: [AskKernelDeliveredResultRecord]) -> String? {
        guard let latestDeliveryRecord = records.first(where: { record in
            record.metadata["assistant_brief_title"] != nil
                || record.metadata["assistant_delivery_channel"] != nil
        }) else {
            return nil
        }

        var parts = ["assistant_delivery"]
        if let channel = clippedText(latestDeliveryRecord.metadata["assistant_delivery_channel"], limit: 32) {
            parts.append("channel=\(channel)")
        }
        if let kind = clippedText(latestDeliveryRecord.metadata["assistant_brief_kind"], limit: 40) {
            parts.append("kind=\(kind)")
        }
        if let title = clippedText(latestDeliveryRecord.metadata["assistant_brief_title"], limit: 56) {
            parts.append("title=\(title)")
        }
        if let taskStatus = clippedText(latestDeliveryRecord.metadata["assistant_delivery_source_task_status"], limit: 24) {
            parts.append("source_task_status=\(taskStatus)")
        }
        return parts.joined(separator: ", ")
    }

    private func clippedText(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }
}
