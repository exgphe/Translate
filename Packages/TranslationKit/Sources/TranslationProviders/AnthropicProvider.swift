import Foundation
import TranslationCore

/// Settings a user supplies for the Anthropic Messages API (bring your own key).
public struct AnthropicConfiguration: Hashable, Codable, Sendable {
    public static let defaultModel = "claude-opus-5-5"
    public static let effortLevels = ["low", "medium", "high"]

    public var apiKey: String
    public var model: String
    /// `output_config.effort`; nil sends the server default.
    public var effort: String?
    public var baseURL: URL
    public var maxOutputTokens: Int

    public init(
        apiKey: String,
        model: String = AnthropicConfiguration.defaultModel,
        effort: String? = "low",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        maxOutputTokens: Int = 16_000
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.baseURL = baseURL
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Direct client for `POST /v1/messages` with streaming. No proxy, no shared key.
public struct AnthropicProvider: TranslationProvider {
    public static let providerID = "anthropic"

    public let id = AnthropicProvider.providerID
    public let displayName = "Anthropic"
    public let capabilities = ProviderCapabilities(
        supportsStreaming: true,
        supportsImages: false,
        processingLocation: .cloud,
        contextBudgetTokens: nil
    )

    public var configuration: AnthropicConfiguration
    private let session: URLSession

    public init(configuration: AnthropicConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? HTTPSupport.makeSession()
    }

    public func availability() async -> ProviderAvailability {
        if configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsConfiguration("Add your Anthropic API key in Settings.")
        }
        if configuration.model.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsConfiguration("Choose a model ID in Settings.")
        }
        return .available
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPSupport.mapTransportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    func makeURLRequest(for request: TranslationRequest) throws -> URLRequest {
        guard !configuration.apiKey.isEmpty else {
            throw TranslationError.missingAPIKey(provider: displayName)
        }
        let prompt = TranslationPrompt(request: request)
        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxOutputTokens,
            "stream": true,
            "system": prompt.instructions,
            "messages": [["role": "user", "content": prompt.input]],
            // Server-side refusal fallback: a classifier decline is retried on the model
            // Anthropic recommends for that category instead of surfacing an empty result.
            "fallbacks": "default",
        ]
        // Effort is not accepted by Haiku 4.5; every current Opus/Sonnet/Fable model takes it.
        if let effort = configuration.effort, !effort.isEmpty, !configuration.model.contains("haiku") {
            body["output_config"] = ["effort": effort]
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func stream(
        _ request: TranslationRequest,
        continuation: AsyncThrowingStream<TranslationEvent, any Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(for: request)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse("Not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw await HTTPSupport.error(for: http, bytes: bytes, providerName: displayName)
        }

        var parser = SSELineParser()
        var modelName = configuration.model
        var usage = TokenUsage()
        var stopReason: String?

        func handle(_ event: ServerSentEvent) throws -> Bool {
            guard let data = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return false }
            switch type {
            case "message_start":
                if let message = object["message"] as? [String: Any] {
                    if let model = message["model"] as? String { modelName = model }
                    if let u = message["usage"] as? [String: Any] {
                        usage.inputTokens = u["input_tokens"] as? Int
                    }
                }
                continuation.yield(.started(modelName: modelName))
            case "content_block_delta":
                if let delta = object["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    continuation.yield(.textDelta(text))
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String
                }
                if let u = object["usage"] as? [String: Any] {
                    usage.outputTokens = u["output_tokens"] as? Int
                    if let input = u["input_tokens"] as? Int { usage.inputTokens = input }
                }
            case "message_stop":
                return true
            case "error":
                let error = object["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "Unknown stream error"
                let kind = error?["type"] as? String ?? ""
                if kind == "overloaded_error" { throw TranslationError.providerError(status: 529, message: message) }
                if kind == "rate_limit_error" { throw TranslationError.rateLimited(retryAfterSeconds: nil) }
                throw TranslationError.providerError(status: 0, message: message)
            default:
                break // ping, content_block_start/stop, thinking deltas, fallback blocks
            }
            return false
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = parser.feed(line: line), try handle(event) { break }
        }
        if let event = parser.flush() { _ = try handle(event) }

        if stopReason == "refusal" {
            throw TranslationError.refused("The service's safety system declined this request.")
        }
        continuation.yield(.completed(TranslationResult(
            requestID: request.id,
            text: "",
            providerID: id,
            modelName: modelName,
            processingLocation: .cloud,
            usage: usage
        )))
    }
}
