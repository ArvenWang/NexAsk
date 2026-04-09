import Foundation

struct AIConfigurationValidationResult {
    let ok: Bool
    let message: String
}

final class AIConfigurationService {
    static let shared = AIConfigurationService()

    private let llmClient: LLMClient
    private let baseURLProvider: () -> String

    init(
        session: URLSession = .shared,
        baseURLProvider: @escaping () -> String = {
            ""
        }
    ) {
        self.llmClient = LLMClient(session: session)
        self.baseURLProvider = baseURLProvider
    }

    func validate(provider: String, model: String, apiKey: String) async -> AIConfigurationValidationResult {
        do {
            let descriptor = try LLMProviderDescriptor.resolve(provider: provider, model: model)
            let overrideBaseURL = baseURLProvider().trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBaseURL: String
            if overrideBaseURL.isEmpty {
                resolvedBaseURL = ProcessInfo.processInfo.environment[descriptor.baseURLEnvironmentKey] ?? descriptor.baseURL
            } else {
                resolvedBaseURL = overrideBaseURL
            }

            guard let url = URL(string: resolvedBaseURL),
                  let scheme = url.scheme,
                  let host = url.host,
                  !scheme.isEmpty,
                  !host.isEmpty else {
                return AIConfigurationValidationResult(
                    ok: false,
                    message: L10n.text(zhHans: "验证失败：AI 服务地址无效。", en: "Validation failed: invalid AI service URL.")
                )
            }

            let configuration = LLMRequestConfiguration(
                provider: descriptor.providerID,
                model: descriptor.defaultModel,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: resolvedBaseURL
            )
            return await llmClient.validate(configuration: configuration)
        } catch {
            return AIConfigurationValidationResult(
                ok: false,
                message: L10n.format(zhHans: "验证失败：%@", en: "Validation failed: %@", error.localizedDescription)
            )
        }
    }
}
