import CaptionFeed
import Foundation
import LiveCaptions
import Testing
import TranslationCore
@testable import Translate

/// Holds the first request while recognition produces more sentences. No model or network.
private actor GatedCaptionTranslator: CaptionTranslating {
    nonisolated let displayName = "Caption test"
    nonisolated let processingLocation = ProcessingLocation.onDevice
    nonisolated let translatesVolatileText = false
    private(set) var requests: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var shouldWait = true

    func translate(_ text: String, previousLines: [String]) async throws -> String {
        requests.append(text)
        if shouldWait {
            shouldWait = false
            await withCheckedContinuation { gate = $0 }
        }
        return "译文：\(text)"
    }

    func release() { gate?.resume(); gate = nil }
}

@MainActor
struct LiveCaptionDisplayTests {
    private func controller() -> LiveCaptionsController {
        let defaults = UserDefaults(suiteName: "CaptionDisplay-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        let controller = LiveCaptionsController(settings: settings, registry: EngineRegistry(settings: settings), defaults: defaults)
        controller.spokenLocaleIdentifier = "en_US"
        controller.targetLanguage = .simplifiedChinese
        controller.translator = .engine("test")
        controller.showsOriginal = false
        return controller
    }

    private func wait(until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }

    @Test func aSlowFirstTranslationDoesNotSkipTheFollowingSentences() async throws {
        let model = controller()
        let translator = GatedCaptionTranslator()
        model.receive(.final("Sentence 0"), translator: translator)
        try await wait { await translator.requests.count == 1 }
        for index in 1..<12 { model.receive(.final("Sentence \(index)"), translator: translator) }
        model.receive(.volatile("Untranslated source"), translator: translator)
        #expect(model.displayItems(now: .now).isEmpty)
        #expect(model.historyItems.isEmpty)
        await translator.release()
        try await wait { model.timeline.lines.allSatisfy { $0.translation != nil } }
        #expect(await translator.requests == (0..<12).map { "Sentence \($0)" })
        #expect(model.historyItems.count == 12)
        #expect(model.historyItems.allSatisfy { $0.secondary == nil })
        #expect(model.displayItems(now: .now).map(\.primary) == ["译文：Sentence 0", "译文：Sentence 1"])
        model.showsOriginal = true
        #expect(model.historyItems.first?.secondary == "Sentence 0")
        model.showsOriginal = false
        #expect(model.historyItems.first?.secondary == nil)
        await model.stop()
    }

    @Test func stopDiscardsAnInFlightResultAndDoesNotDrainTheOldQueue() async throws {
        let model = controller()
        let translator = GatedCaptionTranslator()
        model.receive(.final("First"), translator: translator)
        try await wait { await translator.requests.count == 1 }
        model.receive(.final("Second"), translator: translator)
        await model.stop()
        await translator.release()
        // Resume the cancelled worker and let it reject the late result.
        for _ in 0..<20 { await Task.yield() }
        #expect(model.timeline.lines.allSatisfy { $0.translation == nil })
        #expect(await translator.requests == ["First"])
    }

    @Test func originalOnlyCaptionsRemainVisible() {
        let model = controller()
        model.translator = .off
        model.receive(.final("Original only"), translator: nil)
        #expect(model.displayItems(now: .now).first?.primary == "Original only")
        #expect(model.historyItems.first?.primary == "Original only")
    }
}
