import Foundation
import Testing
import TranslationCore
@testable import TranslationProviders

struct AnthropicRequestTests {
    @Test func buildsStreamingMessagesRequestWithFallbacks() throws {
        let provider = AnthropicProvider(configuration: AnthropicConfiguration(apiKey: "sk-test", model: "claude-opus-5-5", effort: "low"))
        let request = TranslationRequest(sourceText: "Hi", targetLanguage: .simplifiedChinese)
        let urlRequest = try provider.makeURLRequest(for: request)

        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let body = try decode(urlRequest)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["thinking"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect((messages[0]["content"] as? String)?.contains("<source_text>") == true)
        #expect((body["system"] as? String)?.contains("Simplified Chinese") == true)
    }

    @Test func omitsEffortForHaiku() throws {
        let provider = AnthropicProvider(configuration: AnthropicConfiguration(apiKey: "k", model: "claude-haiku-4-5", effort: "low"))
        let urlRequest = try provider.makeURLRequest(for: TranslationRequest(sourceText: "Hi", targetLanguage: .english))
        let body = try decode(urlRequest)
        #expect(body["output_config"] == nil)
    }

    @Test func missingKeyIsReportedBeforeAnyRequest() async throws {
        let provider = AnthropicProvider(configuration: AnthropicConfiguration(apiKey: ""))
        let availability = await provider.availability()
        #expect(availability == .needsConfiguration("Add your Anthropic API key in Settings."))
        #expect(throws: TranslationError.missingAPIKey(provider: "Anthropic")) {
            try provider.makeURLRequest(for: TranslationRequest(sourceText: "Hi", targetLanguage: .english))
        }
    }
}

struct OpenAICompatibleRequestTests {
    @Test func buildsChatCompletionsRequest() async throws {
        let configuration = OpenAICompatibleConfiguration(displayName: "Local", baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "gemma3")
        let provider = OpenAICompatibleProvider(configuration: configuration)
        #expect(provider.capabilities.processingLocation == .localServer)
        let availability = await provider.availability()
        #expect(availability == .available)

        let urlRequest = try provider.makeURLRequest(for: TranslationRequest(sourceText: "Hi", targetLanguage: .japanese))
        #expect(urlRequest.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try decode(urlRequest)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(body["stream"] as? Bool == true)
    }

    @Test func cloudEndpointRequiresKey() async {
        let provider = OpenAICompatibleProvider(configuration: OpenAICompatibleConfiguration(apiKey: "", model: "gpt-x"))
        #expect(provider.capabilities.processingLocation == .cloud)
        let availability = await provider.availability()
        #expect(availability.isAvailable == false)
    }
}

private func decode(_ urlRequest: URLRequest) throws -> [String: Any] {
    let data = try #require(urlRequest.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct HTTPSupportTests {
    @Test func extractsErrorMessages() {
        let anthropic = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        #expect(HTTPSupport.extractMessage(from: anthropic) == "invalid x-api-key")
        let plain = Data("Bad Gateway".utf8)
        #expect(HTTPSupport.extractMessage(from: plain) == "Bad Gateway")
        #expect(HTTPSupport.extractMessage(from: Data()) == nil)
    }

    @Test func classifiesLocalHosts() {
        #expect(HTTPSupport.processingLocation(for: URL(string: "http://127.0.0.1:1234/v1")!) == .localServer)
        #expect(HTTPSupport.processingLocation(for: URL(string: "http://mac-studio.local:8080/v1")!) == .localServer)
        #expect(HTTPSupport.processingLocation(for: URL(string: "https://api.openai.com/v1")!) == .cloud)
    }
}
