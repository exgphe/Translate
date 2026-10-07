import Foundation
import Testing
import TranslationCore
@testable import TranslationProviders

/// Opt-in live test against a real OpenAI-compatible endpoint. Set
/// TRANSLATE_OPENAI_BASE, TRANSLATE_OPENAI_MODEL and TRANSLATE_OPENAI_KEY to enable.
struct LiveOpenAICompatibleTests {
    @Test func translatesAgainstConfiguredEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["TRANSLATE_OPENAI_BASE"], let model = env["TRANSLATE_OPENAI_MODEL"] else { return }
        let configuration = OpenAICompatibleConfiguration(
            displayName: "Live",
            baseURL: try #require(URL(string: base)),
            apiKey: env["TRANSLATE_OPENAI_KEY"] ?? "",
            model: model
        )
        let provider = OpenAICompatibleProvider(configuration: configuration)
        let request = TranslationRequest(sourceText: "Hello, world.", sourceLanguage: .explicit(.english), targetLanguage: .simplifiedChinese)
        var events: [String] = []
        var result: TranslationResult?
        for try await event in TranslationCoordinator().run(request, using: provider) {
            switch event {
            case .started(let name): events.append("started:\(name)")
            case .text(let text): events.append("text:\(text)")
            case .completed(let r): result = r
            default: break
            }
        }
        print("LIVE EVENTS:", events)
        print("LIVE RESULT:", result as Any)
        #expect(result?.text.isEmpty == false)
    }
}
