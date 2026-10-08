@preconcurrency import AVFAudio
import Foundation
import Testing
import TranslationCore
@testable import LiveCaptions

struct CaptionTimelineTests {
    @Test func volatileTextIsReplacedThenFinalized() {
        var timeline = CaptionTimeline()
        timeline.updateVolatile("The meet")
        timeline.updateVolatile("The meeting is")
        #expect(timeline.volatileOriginal == "The meeting is")
        let line = timeline.appendFinal("The meeting is moved.")
        #expect(line?.id == 0)
        #expect(timeline.lines.map(\.original) == ["The meeting is moved."])
        #expect(timeline.volatileOriginal.isEmpty)
    }

    @Test func finalRemovesOnlyTheCoveredVolatilePrefix() {
        var timeline = CaptionTimeline()
        timeline.updateVolatile("Hello there. How are")
        timeline.appendFinal("Hello there.")
        #expect(timeline.volatileOriginal == "How are")
    }

    @Test func translationsAttachToTheirLine() {
        var timeline = CaptionTimeline()
        let first = timeline.appendFinal("One.")!
        let second = timeline.appendFinal("Two.")!
        timeline.setTranslation("二。", forLine: second.id)
        timeline.markTranslationFailed(forLine: first.id)
        #expect(timeline.lines[1].translation == "二。")
        #expect(timeline.lines[0].translationFailed)
        #expect(timeline.context(before: second.id, count: 3) == ["One."])
        #expect(timeline.transcript == "One.\n\nTwo.\n二。")
    }

    @Test func staleVolatileTranslationIsIgnored() {
        var timeline = CaptionTimeline()
        timeline.updateVolatile("Good morning")
        timeline.setVolatileTranslation("早上好", source: "Good morning")
        #expect(timeline.volatileTranslation == "早上好")
        timeline.appendFinal("Good morning everyone.")
        timeline.setVolatileTranslation("早上好", source: "Good morning")
        #expect(timeline.volatileTranslation == nil)
    }

    @Test func recentLinesRespectTimeWindowAndLimit() {
        var timeline = CaptionTimeline()
        let now = Date()
        timeline.appendFinal("old", at: now.addingTimeInterval(-30))
        timeline.appendFinal("a", at: now.addingTimeInterval(-3))
        timeline.appendFinal("b", at: now.addingTimeInterval(-2))
        timeline.appendFinal("c", at: now.addingTimeInterval(-1))
        #expect(timeline.recentLines(limit: 2, within: 10, now: now).map(\.original) == ["b", "c"])
    }

    @Test func historyIsCapped() {
        var timeline = CaptionTimeline(maximumLines: 3)
        for index in 0..<5 { timeline.appendFinal("line \(index)") }
        #expect(timeline.lines.map(\.original) == ["line 2", "line 3", "line 4"])
    }
}

/// Echoes the prompt's context so tests can check what the caption translator sends.
private struct ContextEchoProvider: TranslationProvider {
    let id = "echo"
    let displayName = "Echo"
    let capabilities = ProviderCapabilities(supportsStreaming: true, supportsImages: false, processingLocation: .onDevice)

    func availability() async -> ProviderAvailability { .available }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textSnapshot("[\(request.targetLanguage.identifier)] \(request.sourceText) | \(request.context ?? "")"))
            continuation.finish()
        }
    }
}

struct ProviderCaptionTranslatorTests {
    @Test func sendsTheLineWithPrecedingLinesAsContext() async throws {
        let translator = ProviderCaptionTranslator(
            provider: ContextEchoProvider(),
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese,
            networkPolicy: .allowCloud
        )
        let output = try await translator.translate("is moved to Thursday.", previousLines: ["The meeting"])
        #expect(output.hasPrefix("[zh-Hans] is moved to Thursday."))
        #expect(output.contains("automatic speech recognition"))
        #expect(output.contains("The meeting"))
        #expect(!translator.translatesVolatileText)
    }
}

/// Real on-device recognition of synthesized speech, streamed in 100 ms chunks like live audio.
struct LiveTranscriberTests {
    private func synthesize(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "live-captions-\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        return url
    }

    private func chunks(of url: URL) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        var result: [AudioChunk] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            result.append(AudioChunk(buffer: buffer))
        }
        return result
    }

    @Test(.timeLimit(.minutes(3)))
    func transcribesStreamedSpeech() async throws {
        let transcriber = try await LiveTranscriber.prepare(locale: Locale(identifier: "en-US"))
        let url = try synthesize("The meeting has been moved to Thursday. Please bring the signed forms.")
        defer { try? FileManager.default.removeItem(at: url) }
        let pieces = try chunks(of: url)
        #expect(pieces.count > 10)

        let (audio, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        let producer = Task {
            for piece in pieces {
                feed.yield(piece)
                try? await Task.sleep(for: .milliseconds(5))
            }
            feed.finish()
        }

        var finals: [String] = []
        var volatileCount = 0
        for try await event in transcriber.transcribe(audio) {
            switch event {
            case .volatile: volatileCount += 1
            case .final(let text): finals.append(text)
            }
        }
        await producer.value
        let transcript = finals.joined(separator: " ").lowercased()
        print("LIVE TRANSCRIPT:", transcript, "volatile updates:", volatileCount)
        #expect(transcript.contains("thursday"))
        #expect(transcript.contains("signed forms"))
    }
}
