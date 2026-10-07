import Foundation
import Testing
@testable import TranslationCore

struct SSEParserTests {
    @Test func parsesMultiLineDataAndEventNames() {
        var parser = SSELineParser()
        let e1 = parser.feed(line: "event: content_block_delta")
        let e2 = parser.feed(line: "data: {\"a\":1,")
        let e3 = parser.feed(line: "data:  \"b\":2}")
        #expect(e1 == nil && e2 == nil && e3 == nil)
        let event = parser.feed(line: "")
        #expect(event == ServerSentEvent(event: "content_block_delta", data: "{\"a\":1,\n \"b\":2}"))
        let trailing = parser.feed(line: "")
        #expect(trailing == nil)
    }

    @Test func ignoresCommentsAndHandlesCRLF() {
        var parser = SSELineParser()
        let comment = parser.feed(line: ": keep-alive")
        let partial = parser.feed(line: "data: hello\r")
        let event = parser.feed(line: "\r")
        #expect(comment == nil && partial == nil)
        #expect(event?.data == "hello")
    }

    @Test func flushEmitsTrailingEvent() {
        var parser = SSELineParser()
        _ = parser.feed(line: "data: [DONE]")
        let flushed = parser.flush()
        let again = parser.flush()
        #expect(flushed?.data == "[DONE]")
        #expect(again == nil)
    }
}

struct LineSplitterTests {
    @Test func preservesEmptyLinesAndHandlesCRLF() {
        var splitter = LineSplitter()
        var lines: [String] = []
        for byte in Array("data: a\n\ndata: b\r\n\r\ntail".utf8) {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        let trailing = splitter.flush()
        #expect(lines == ["data: a", "", "data: b", ""])
        #expect(trailing == "tail")
    }

    @Test func sseEventsAreDelimitedByTheBlankLines() {
        var splitter = LineSplitter()
        var parser = SSELineParser()
        var events: [ServerSentEvent] = []
        for byte in Array("data: {\"a\":1}\n\ndata: {\"a\":2}\n\ndata: [DONE]\n\n".utf8) {
            guard let line = splitter.feed(byte) else { continue }
            if let event = parser.feed(line: line) { events.append(event) }
        }
        #expect(events.map(\.data) == ["{\"a\":1}", "{\"a\":2}", "[DONE]"])
    }
}

struct AccumulatorTests {
    @Test func deltasAppendAndSnapshotsReplace() {
        var acc = StreamedTextAccumulator()
        let a = acc.apply(.textDelta("Hel"))
        let b = acc.apply(.textDelta("lo"))
        #expect(a && b)
        #expect(acc.text == "Hello")
        let c = acc.apply(.textSnapshot("Hello world"))
        let d = acc.apply(.textSnapshot("Hello world"))
        let e = acc.apply(.textDelta(""))
        #expect(c && !d && !e)
        #expect(acc.text == "Hello world")
    }
}

struct PromptTests {
    @Test func translatePromptNamesLanguagesAndWrapsText() {
        let request = TranslationRequest(
            sourceText: "Bonjour",
            sourceLanguage: .explicit(LanguageCode("fr")),
            targetLanguage: .simplifiedChinese,
            context: "A greeting in a formal email."
        )
        let prompt = TranslationPrompt(request: request)
        #expect(prompt.instructions.contains("into Simplified Chinese"))
        #expect(prompt.instructions.contains("Source language: French"))
        #expect(prompt.instructions.contains("formal email"))
        #expect(prompt.input == "<source_text>\nBonjour\n</source_text>")
    }

    @Test func detectedLanguageIsReportedAsLikely() {
        var request = TranslationRequest(sourceText: "こんにちは", targetLanguage: .english)
        request.detectedSourceLanguage = .japanese
        let prompt = TranslationPrompt(request: request)
        #expect(prompt.instructions.contains("auto-detect (likely Japanese)"))
    }

    @Test func explainPromptIncludesTranslationAndFocus() {
        let request = TranslationRequest(
            sourceText: "Break a leg!",
            targetLanguage: .simplifiedChinese,
            mode: .explain(focus: "break a leg"),
            priorTranslation: "祝你好运！"
        )
        let prompt = TranslationPrompt(request: request)
        #expect(prompt.input.contains("<translation>\n祝你好运！\n</translation>"))
        #expect(prompt.input.contains("Explain specifically this part: \"break a leg\""))
    }
}

struct TokenEstimatorTests {
    @Test func cjkCountsPerCharacter() {
        #expect(TokenEstimator.estimate("你好世界") == 4)
        #expect(TokenEstimator.estimate("hello world") == 4)
        #expect(TokenEstimator.estimate("") == 0)
    }
}

struct LanguageDetectorTests {
    @Test func detectsObviousLanguages() {
        let detector = LanguageDetector()
        #expect(detector.detect("The quick brown fox jumps over the lazy dog.") == .english)
        #expect(detector.detect("今天天气真不错，我们一起去公园散步吧。")?.identifier.hasPrefix("zh") == true)
        #expect(detector.detect("") == nil)
    }
}

/// A scripted provider for coordinator tests.
struct ScriptedProvider: TranslationProvider {
    let id = "scripted"
    let displayName = "Scripted"
    var capabilities = ProviderCapabilities(supportsStreaming: true, supportsImages: false, processingLocation: .onDevice, contextBudgetTokens: nil)
    var events: [TranslationEvent]
    var delayNanoseconds: UInt64 = 0

    func availability() async -> ProviderAvailability { .available }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct CoordinatorTests {
    @Test func foldsDeltasIntoSnapshotsAndCompletes() async throws {
        let provider = ScriptedProvider(events: [
            .started(modelName: "m"), .textDelta("你"), .textDelta("好"), .textSnapshot("你好。\n"),
        ])
        let request = TranslationRequest(sourceText: "Hello.", targetLanguage: .simplifiedChinese)
        var texts: [String] = []
        var completed: TranslationResult?
        for try await event in TranslationCoordinator().run(request, using: provider) {
            switch event {
            case .text(let text): texts.append(text)
            case .completed(let result): completed = result
            default: break
            }
        }
        #expect(texts == ["你", "你好", "你好。\n", "你好。"])
        #expect(completed?.text == "你好。")
        #expect(completed?.modelName == "m")
        #expect(completed?.requestID == request.id)
    }

    @Test func rejectsEmptyInput() async {
        let provider = ScriptedProvider(events: [])
        let request = TranslationRequest(sourceText: "   \n", targetLanguage: .english)
        await #expect(throws: TranslationError.emptyInput) {
            for try await _ in TranslationCoordinator().run(request, using: provider) {}
        }
    }

    @Test func enforcesOnDevicePolicy() async {
        var provider = ScriptedProvider(events: [])
        provider.capabilities.processingLocation = .cloud
        let request = TranslationRequest(sourceText: "Hi", targetLanguage: .english, networkPolicy: .onDeviceOnly)
        await #expect(throws: TranslationError.self) {
            for try await _ in TranslationCoordinator().run(request, using: provider) {}
        }
    }

    @Test func refusesOversizedPromptForLimitedEngines() async {
        var provider = ScriptedProvider(events: [])
        provider.capabilities.contextBudgetTokens = 50
        let request = TranslationRequest(sourceText: String(repeating: "字", count: 200), targetLanguage: .english)
        await #expect(throws: TranslationError.self) {
            for try await _ in TranslationCoordinator().run(request, using: provider) {}
        }
    }

    @Test func cancellationStopsTheProvider() async throws {
        let provider = ScriptedProvider(events: Array(repeating: .textDelta("x"), count: 50), delayNanoseconds: 20_000_000)
        let request = TranslationRequest(sourceText: "Hi", targetLanguage: .english)
        let task = Task {
            var count = 0
            for try await event in TranslationCoordinator().run(request, using: provider) {
                if case .text = event { count += 1 }
                if count == 3 { throw CancellationError() }
            }
            return count
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func emptyResultIsAnError() async {
        let provider = ScriptedProvider(events: [.started(modelName: "m")])
        let request = TranslationRequest(sourceText: "Hi", targetLanguage: .english)
        await #expect(throws: TranslationError.self) {
            for try await _ in TranslationCoordinator().run(request, using: provider) {}
        }
    }

    @Test func stripsEchoedWrapperTags() {
        #expect(TranslationCoordinator.cleanOutput("<translation>\nHola\n</translation>") == "Hola")
        #expect(TranslationCoordinator.cleanOutput("  Hola \n") == "Hola")
    }
}
