import Foundation
import TranslationCore

/// Settings for any service that speaks the OpenAI Chat Completions protocol
/// (OpenAI, OpenRouter, DeepSeek, Gemini's compatibility endpoint, Ollama, LM Studio, ...).
public struct OpenAICompatibleConfiguration: Hashable, Codable, Sendable {
    public var displayName: String
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    /// Sent only when set. Many current models (OpenAI's gpt-5 family and later reasoning
    /// models) reject any non-default temperature, so the default is to leave it to the server.
    public var temperature: Double?

    public init(
        displayName: String = "OpenAI-compatible",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        apiKey: String = "",
        model: String = "",
        temperature: Double? = nil
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
    }
}

public struct OpenAICompatibleProvider: TranslationProvider {
    public static let providerID = "openai-compatible"

    public let id = OpenAICompatibleProvider.providerID
    public var displayName: String { configuration.displayName }
    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportsStreaming: true,
            supportsImages: false,
            processingLocation: HTTPSupport.processingLocation(for: configuration.baseURL),
            contextBudgetTokens: nil
        )
    }

    public var configuration: OpenAICompatibleConfiguration
    private let session: URLSession

    public init(configuration: OpenAICompatibleConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? HTTPSupport.makeSession()
    }

    public func availability() async -> ProviderAvailability {
        if configuration.model.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsConfiguration("Enter the model name in Settings.")
        }
        // Local servers often need no key; cloud services do.
        if configuration.apiKey.isEmpty, capabilities.processingLocation == .cloud {
            return .needsConfiguration("Add the API key for \(configuration.displayName) in Settings.")
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

    func makeURLRequest(for request: TranslationRequest, includeTemperature: Bool = true) throws -> URLRequest {
        let prompt = TranslationPrompt(request: request)
        var body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": [
                ["role": "system", "content": prompt.instructions],
                ["role": "user", "content": prompt.input],
            ],
        ]
        if includeTemperature, let temperature = configuration.temperature {
            body["temperature"] = temperature
        }
        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func stream(
        _ request: TranslationRequest,
        continuation: AsyncThrowingStream<TranslationEvent, any Error>.Continuation,
        includeTemperature: Bool = true
    ) async throws {
        let urlRequest = try makeURLRequest(for: request, includeTemperature: includeTemperature)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse("Not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = await HTTPSupport.error(for: http, bytes: bytes, providerName: displayName)
            // Models that only accept the default temperature reject the parameter outright.
            // Nothing has been streamed yet, so retrying once without it is safe.
            if includeTemperature, configuration.temperature != nil, Self.isTemperatureRejection(error) {
                try await stream(request, continuation: continuation, includeTemperature: false)
                return
            }
            throw error
        }

        var modelName = configuration.model
        var usage = TokenUsage()
        var finishReason: String?
        var started = false
        var sawText = false
        var lastPayload = ""

        func extractText(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            // Some servers send content as an array of parts.
            if let parts = value as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                return text.isEmpty ? nil : text
            }
            return nil
        }

        func handleObject(_ object: [String: Any]) throws {
            if let error = object["error"] as? [String: Any] {
                throw TranslationError.providerError(status: 0, message: error["message"] as? String ?? "Unknown error")
            }
            if let model = object["model"] as? String, !model.isEmpty { modelName = model }
            if !started {
                started = true
                continuation.yield(.started(modelName: modelName))
            }
            if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
                if let delta = first["delta"] as? [String: Any], let content = extractText(delta["content"]) {
                    sawText = sawText || !content.isEmpty
                    continuation.yield(.textDelta(content))
                } else if let message = first["message"] as? [String: Any], let content = extractText(message["content"]) {
                    // Non-streaming shape: the whole answer in one object.
                    sawText = sawText || !content.isEmpty
                    continuation.yield(.textSnapshot(content))
                }
                if let reason = first["finish_reason"] as? String { finishReason = reason }
            }
            if let u = object["usage"] as? [String: Any] {
                usage.inputTokens = u["prompt_tokens"] as? Int
                usage.outputTokens = u["completion_tokens"] as? Int
            }
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") || contentType.isEmpty || contentType.contains("application/x-ndjson") {
            try await HTTPSupport.forEachEvent(in: bytes) { event in
                let payload = event.data.trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { return true }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                lastPayload = String(payload.prefix(300))
                try handleObject(object)
                return false
            }
        } else {
            // The server ignored `stream: true` and answered with one JSON document.
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            lastPayload = String(decoding: body.prefix(300), as: UTF8.self)
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw TranslationError.invalidResponse("Expected JSON or an event stream, got \(contentType.isEmpty ? "no content type" : contentType): \(lastPayload)")
            }
            try handleObject(object)
        }

        if finishReason == "content_filter" {
            throw TranslationError.refused("The service's content filter declined this request.")
        }
        guard sawText else {
            throw TranslationError.invalidResponse("The service returned no text. Last payload: \(lastPayload.isEmpty ? "(empty body)" : lastPayload)")
        }
        continuation.yield(.completed(TranslationResult(
            requestID: request.id,
            text: "",
            providerID: id,
            modelName: modelName,
            processingLocation: capabilities.processingLocation,
            usage: usage
        )))
    }

    static func isTemperatureRejection(_ error: TranslationError) -> Bool {
        guard case .providerError(let status, let message) = error, status == 400 else { return false }
        return message.localizedCaseInsensitiveContains("temperature")
    }
}
