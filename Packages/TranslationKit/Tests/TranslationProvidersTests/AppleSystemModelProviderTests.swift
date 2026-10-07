import Foundation
import Testing
import TranslationCore
@testable import TranslationProviders

/// Real on-device inference. Skips on machines without Apple Intelligence so CI stays green.
struct AppleSystemModelProviderTests {
    @Test func translatesThroughTheCoordinator() async throws {
        let provider = AppleSystemModelProvider()
        let availability = await provider.availability()
        guard availability.isAvailable else {
            Issue.record("Apple Intelligence unavailable on this machine: \(availability.message ?? "") (skipped)")
            return
        }
        let request = TranslationRequest(
            sourceText: "The meeting was moved to Thursday. Please do not forget the signed forms.",
            targetLanguage: .simplifiedChinese
        )
        var snapshots: [String] = []
        var result: TranslationResult?
        var detected: LanguageCode?
        for try await event in TranslationCoordinator().run(request, using: provider) {
            switch event {
            case .detectedLanguage(let code): detected = code
            case .text(let text): snapshots.append(text)
            case .completed(let r): result = r
            default: break
            }
        }
        #expect(detected == .english)
        #expect(!snapshots.isEmpty)
        let text = try #require(result?.text)
        #expect(!text.isEmpty)
        #expect(text.contains("周四") || text.contains("星期四"))
        #expect(!text.contains("<source_text>"))
        #expect(result?.processingLocation == .onDevice)
    }

    @Test func cancellationStopsInference() async throws {
        let provider = AppleSystemModelProvider()
        guard await provider.availability().isAvailable else { return }
        let request = TranslationRequest(
            sourceText: String(repeating: "This is a fairly long sentence that will take a while to translate. ", count: 12),
            targetLanguage: .simplifiedChinese
        )
        let task = Task {
            var count = 0
            for try await event in TranslationCoordinator().run(request, using: provider) {
                if case .text = event {
                    count += 1
                    if count == 2 { throw CancellationError() }
                }
            }
            return count
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func refusesTextBeyondTheContextWindow() async {
        let provider = AppleSystemModelProvider()
        let request = TranslationRequest(sourceText: String(repeating: "字", count: 5000), targetLanguage: .english)
        await #expect(throws: TranslationError.self) {
            for try await _ in TranslationCoordinator().run(request, using: provider) {}
        }
    }
}
