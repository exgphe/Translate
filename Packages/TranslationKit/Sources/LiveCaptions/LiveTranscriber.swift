@preconcurrency import AVFAudio
import Foundation
import Speech

/// What the recognizer reports while audio streams in.
public enum TranscriptEvent: Hashable, Sendable {
    /// The phrase being recognized right now; replaces the previous volatile text.
    case volatile(String)
    /// A phrase the recognizer will not revise any more.
    case final(String)
}

/// Streaming, on-device speech recognition with SpeechAnalyzer and SpeechTranscriber.
public struct LiveTranscriber: Sendable {
    public let locale: Locale

    private init(locale: Locale) {
        self.locale = locale
    }

    /// Languages the recognizer supports on this device, sorted by display name.
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
    }

    /// Resolves the locale and makes sure its model is installed for this app, downloading it
    /// if needed. `progress` receives 0...1 while a download runs.
    public static func prepare(
        locale requested: Locale,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LiveTranscriber {
        guard SpeechTranscriber.isAvailable else { throw LiveCaptionsError.speechRecognitionUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw LiveCaptionsError.unsupportedSpokenLanguage(requested.localizedString(forIdentifier: requested.identifier) ?? requested.identifier)
        }
        let probe = Self.makeTranscriber(locale: locale)
        if await AssetInventory.status(forModules: [probe]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                let watcher = Task {
                    while !Task.isCancelled {
                        progress(request.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                defer { watcher.cancel() }
                try await request.downloadAndInstall()
                progress(1)
            }
        }
        return LiveTranscriber(locale: locale)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// Recognizes `audio` until it ends or the consumer stops iterating.
    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let locale = self.locale
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(locale: locale, audio: audio, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        locale: Locale,
        audio: AsyncStream<AudioChunk>,
        continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation
    ) async throws {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            throw LiveCaptionsError.noAudioFormat
        }

        try await runStreamingSession(
            start: {
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                try await analyzer.start(inputSequence: inputs)
            },
            input: {
                defer { inputContinuation.finish() }
                let converter = BufferConverter(target: format)
                for await chunk in audio {
                    try Task.checkCancellation()
                    if let converted = try converter.convert(chunk.buffer) {
                        inputContinuation.yield(AnalyzerInput(buffer: converted))
                    }
                }
                try Task.checkCancellation()
                inputContinuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            },
            results: {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    continuation.yield(result.isFinal ? .final(text) : .volatile(text))
                }
            },
            cancel: {
                inputContinuation.finish()
                await analyzer.cancelAndFinishNow()
            }
        )
    }
}
