import Foundation
import NexShared

struct AskSessionResponse: Equatable {
    let message: String
    let cards: [SkillResultCard]
    let metadata: [String: String]
}

enum AskSessionStreamEvent: Equatable {
    case status(String, detail: String?)
    case runtimeStep(AskRuntimeStepEvent)
    case assistantPreamble(String)
    case delta(String, fullText: String)
    case done(AskSessionResponse)
    case failed(String, detail: String?)
}

enum AskSessionServiceError: LocalizedError, Equatable {
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.text(zhHans: "Ask 会话返回了无效响应。", en: "The Ask session returned an invalid response.")
        case .network(let message):
            return message
        }
    }
}

final class AskSessionService {
    private final class AskStreamEventPump {
        private static let frameInterval: TimeInterval = 1.0 / 60.0
        private static let maxNonDeltaEventsPerDrain = 4
        private static let maxDeltaCharactersPerDrain = 16
        private let diagnosticsLogger = DiagnosticsLogger.shared
        private let onEvent: @Sendable (AskSessionStreamEvent) -> Void
        private let onComplete: @Sendable (Result<AskSessionResponse, Error>) -> Void
        private let queue = DispatchQueue(label: "nexhub.ask.stream-event-pump")

        private var bufferedEvents: [AskSessionStreamEvent] = []
        private var pendingCompletion: Result<AskSessionResponse, Error>?
        private var drainScheduled = false

        init(
            onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void,
            onComplete: @escaping @Sendable (Result<AskSessionResponse, Error>) -> Void
        ) {
            self.onEvent = onEvent
            self.onComplete = onComplete
        }

        func enqueue(_ event: AskSessionStreamEvent) {
            queue.async {
                if case .delta(let delta, let fullText) = event,
                   case .delta(let existingDelta, _) = self.bufferedEvents.last {
                    self.bufferedEvents[self.bufferedEvents.count - 1] = .delta(
                        existingDelta + delta,
                        fullText: fullText
                    )
                } else if case .runtimeStep(let step) = event,
                          case .runtimeStep(let existingStep) = self.bufferedEvents.last,
                          existingStep.id == step.id {
                    self.bufferedEvents[self.bufferedEvents.count - 1] = event
                } else {
                    self.bufferedEvents.append(event)
                }
                self.scheduleDrainLocked()
            }
        }

        func finish(_ result: Result<AskSessionResponse, Error>) {
            queue.async {
                self.pendingCompletion = result
                self.drainScheduled = false
                self.diagnosticsLogger.log(
                    "ask.pump",
                    "finish_queued buffered_events=\(self.bufferedEvents.count) pending_completion=true"
                )
                self.scheduleDrainLocked()
            }
        }

        private func scheduleDrainLocked() {
            guard !drainScheduled else { return }
            drainScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.frameInterval) {
                self.drainOnMain()
            }
        }

        private func drainOnMain() {
            let payload: (events: [AskSessionStreamEvent], completion: Result<AskSessionResponse, Error>?, remainingBufferedEvents: Int, pendingCompletionAfterDequeue: Bool) = queue.sync {
                let events = dequeueEventsLocked()
                let completion: Result<AskSessionResponse, Error>?
                if bufferedEvents.isEmpty {
                    completion = pendingCompletion
                    pendingCompletion = nil
                } else {
                    completion = nil
                }
                drainScheduled = false
                return (events, completion, bufferedEvents.count, pendingCompletion != nil)
            }

            payload.events.forEach(onEvent)
            if let completion = payload.completion {
                diagnosticsLogger.log(
                    "ask.pump",
                    "finish_delivered events_in_tick=\(payload.events.count) remaining_buffered=\(payload.remainingBufferedEvents)"
                )
                onComplete(completion)
            }

            queue.async {
                guard (!self.bufferedEvents.isEmpty || self.pendingCompletion != nil), !self.drainScheduled else {
                    return
                }
                self.scheduleDrainLocked()
            }
        }

        private func dequeueEventsLocked() -> [AskSessionStreamEvent] {
            guard let first = bufferedEvents.first else { return [] }

            switch first {
            case .delta(let delta, let fullText):
                let deltaCharacterCount = delta.count
                guard deltaCharacterCount > Self.maxDeltaCharactersPerDrain else {
                    bufferedEvents.removeFirst()
                    return [first]
                }

                let splitIndex = delta.index(
                    delta.startIndex,
                    offsetBy: Self.maxDeltaCharactersPerDrain,
                    limitedBy: delta.endIndex
                ) ?? delta.endIndex
                let visibleDelta = String(delta[..<splitIndex])
                let remainingDelta = String(delta[splitIndex...])
                let remainingCount = remainingDelta.count
                let visibleFullText = remainingCount > 0
                    ? String(fullText.dropLast(remainingCount))
                    : fullText
                bufferedEvents[0] = .delta(remainingDelta, fullText: fullText)
                return [.delta(visibleDelta, fullText: visibleFullText)]
            default:
                var result: [AskSessionStreamEvent] = []
                while result.count < Self.maxNonDeltaEventsPerDrain,
                      let next = bufferedEvents.first {
                    if case .delta = next {
                        break
                    }
                    result.append(bufferedEvents.removeFirst())
                }
                return result
            }
        }
    }

    private static let mainQueueSpecificKey: DispatchSpecificKey<UInt8> = {
        let key = DispatchSpecificKey<UInt8>()
        DispatchQueue.main.setSpecific(key: key, value: 1)
        return key
    }()

    private let session: URLSession
    private let settings: AppSettings
    private let knowledgeBasePayloadProvider: () -> [String: Any]?
    private let knowledgeBaseManifestProvider: () -> [[String: Any]]
    private let runtimeService: AskSkillRuntimeService
    private let managedConfigurationProvider: () -> LLMRequestConfiguration?

    init(
        session: URLSession = .shared,
        settings: AppSettings = .shared,
        runtimeService: AskSkillRuntimeService = .shared,
        managedConfigurationProvider: @escaping () -> LLMRequestConfiguration? = {
            ManagedAIConfigurationService.shared.currentConfiguration()
        },
        knowledgeBasePayloadProvider: @escaping () -> [String: Any]? = {
            ReplyKnowledgeBaseStore.shared.requestPayload()
        },
        knowledgeBaseManifestProvider: @escaping () -> [[String: Any]] = {
            ReplyKnowledgeBaseStore.shared.entries()
                .filter { $0.isEnabled != false }
                .prefix(24)
                .map { entry in
                    var item: [String: Any] = [
                        "id": entry.id,
                        "title": entry.originalFilename.isEmpty ? entry.title : entry.originalFilename,
                        "summary": entry.summary,
                        "source_kind": entry.sourceKind?.rawValue ?? "",
                        "content_kind": entry.contentKind?.rawValue ?? "",
                        "language": entry.languageCode ?? "",
                        "is_enabled": entry.isEnabled != false
                    ]
                    if let externalURL = entry.externalURL, !externalURL.isEmpty {
                        item["external_url"] = externalURL
                    }
                    if let sourceIdentifier = entry.sourceIdentifier, !sourceIdentifier.isEmpty {
                        item["source_identifier"] = sourceIdentifier
                    }
                    return item
                }
        }
    ) {
        self.session = session
        self.settings = settings
        self.runtimeService = runtimeService
        self.managedConfigurationProvider = managedConfigurationProvider
        self.knowledgeBasePayloadProvider = knowledgeBasePayloadProvider
        self.knowledgeBaseManifestProvider = knowledgeBaseManifestProvider
    }

    @discardableResult
    func streamReply(
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void,
        onComplete: @escaping @Sendable (Result<AskSessionResponse, Error>) -> Void
    ) -> Task<Void, Never> {
        let pump = AskStreamEventPump(onEvent: onEvent, onComplete: onComplete)
        return Task {
            do {
                let response = try await runtimeService.streamAsk(request: request) { event in
                    pump.enqueue(event)
                }
                pump.finish(.success(response))
            } catch is CancellationError {
                pump.finish(.failure(CancellationError()))
            } catch {
                let mapped = askSessionError(for: error)
                pump.enqueue(.failed(mapped.localizedDescription, detail: nil))
                pump.finish(.failure(mapped))
            }
        }
    }

    private func deliverOnMain(_ work: @escaping () -> Void) {
        _ = Self.mainQueueSpecificKey
        if DispatchQueue.getSpecific(key: Self.mainQueueSpecificKey) == 1 {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func askSessionResponse(from payload: [String: Any]) -> AskSessionResponse? {
        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return nil }

        let cards: [SkillResultCard]
        if let rawCards = payload["cards"] {
            cards = decodeCards(from: rawCards)
        } else {
            cards = []
        }

        let metadata: [String: String]
        if let rawMetadata = payload["metadata"] as? [String: Any] {
            metadata = rawMetadata.reduce(into: [:]) { partial, item in
                partial[item.key] = String(describing: item.value)
            }
        } else if let rawMetadata = payload["metadata"] as? [String: String] {
            metadata = rawMetadata
        } else {
            metadata = [:]
        }

        return AskSessionResponse(message: message, cards: cards, metadata: metadata)
    }

    private func decodeCards(from payload: Any) -> [SkillResultCard] {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let cards = try? JSONDecoder().decode([SkillResultCard].self, from: data) else {
            return []
        }
        return cards
    }

    static func mergeStreamingText(current: String, incoming: String) -> (appended: String, fullText: String) {
        let normalizedIncoming = incoming.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedIncoming.isEmpty else {
            return ("", current)
        }

        guard !current.isEmpty else {
            return (normalizedIncoming, normalizedIncoming)
        }

        if normalizedIncoming == current || current.hasSuffix(normalizedIncoming) {
            return ("", current)
        }

        if normalizedIncoming.hasPrefix(current) {
            let remainder = String(normalizedIncoming.dropFirst(current.count))
            return (remainder, normalizedIncoming)
        }

        let overlap = longestSuffixPrefixOverlap(current: current, incoming: normalizedIncoming)
        if overlap > 0 {
            let remainder = String(normalizedIncoming.dropFirst(overlap))
            return (remainder, current + remainder)
        }

        return (normalizedIncoming, current + normalizedIncoming)
    }

    func makeRequest(for requestModel: AskSessionRequest) throws -> URLRequest {
        guard let requestURL = URL(string: "nexhub://builtin-runtime/v1/ask/stream") else {
            throw AskSessionServiceError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppBrand.clientIdentifier, forHTTPHeaderField: "X-NexHub-Client")

        if let managedConfiguration = managedConfigurationProvider() {
            request.setValue("Bearer \(managedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(managedConfiguration.provider, forHTTPHeaderField: "X-LLM-Provider")
            request.setValue(managedConfiguration.model, forHTTPHeaderField: "X-LLM-Model")
        }

        let sessionMetadata: [String: Any] = [
            "session_id": requestModel.metadata.sessionID,
            "source_bundle_id": requestModel.metadata.sourceBundleID ?? "",
            "source_app_name": requestModel.metadata.sourceAppName ?? "",
            "invocation_surface": requestModel.metadata.invocationSurface.rawValue,
            "requested_mode": requestModel.metadata.requestedMode?.rawValue ?? "",
            "kernel_metadata": requestModel.metadata.kernelMetadata,
            "frame": [
                "x": requestModel.metadata.frame.origin.x,
                "y": requestModel.metadata.frame.origin.y,
                "width": requestModel.metadata.frame.width,
                "height": requestModel.metadata.frame.height
            ]
        ]

        var body: [String: Any] = [
            "messages": requestModel.messages.map {
                [
                    "role": $0.role.rawValue,
                    "content": $0.content
                ]
            },
            "ui_language": requestModel.uiLanguage,
            "response_language": requestModel.responseLanguage,
            "session_metadata": sessionMetadata
        ]

        if var knowledgeBasePayload = knowledgeBasePayloadProvider() {
            knowledgeBasePayload["enabled"] = true
            body["knowledge_base"] = knowledgeBasePayload
        }
        let manifest = knowledgeBaseManifestProvider()
        if !manifest.isEmpty {
            body["knowledge_base_manifest"] = manifest
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func askSessionError(for error: Error) -> AskSessionServiceError {
        if let askError = error as? AskSessionServiceError {
            return askError
        }
        if let llmError = error as? LLMClientError {
            switch llmError {
            case .invalidResponse:
                return .invalidResponse
            case .server(let message):
                return .network(message)
            case .unsupportedProvider, .missingAPIKey, .invalidBaseURL:
                return .network(llmError.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }

    private static func longestSuffixPrefixOverlap(current: String, incoming: String) -> Int {
        let currentCharacters = Array(current)
        let incomingCharacters = Array(incoming)
        let maxOverlap = min(currentCharacters.count, incomingCharacters.count)
        guard maxOverlap > 0 else { return 0 }

        for size in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(currentCharacters.suffix(size)) == Array(incomingCharacters.prefix(size)) {
                return size
            }
        }
        return 0
    }

    private func gatewayResponseError(data: Data?) -> AskSessionServiceError {
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidResponse
        }

        let message = [
            payload["message"] as? String,
            payload["error"] as? String,
            payload["detail"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        guard let message else { return .invalidResponse }
        return .network(message)
    }

    private func collectGatewayErrorData(from bytes: URLSession.AsyncBytes) async throws -> Data? {
        var lines: [String] = []

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            if lines.joined(separator: "\n").count >= 2048 {
                break
            }
        }

        guard !lines.isEmpty else { return nil }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
