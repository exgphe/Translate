import Foundation

/// Events the UI consumes. Text is always a full snapshot here.
public enum CoordinatorEvent: Hashable, Sendable {
    case detectedLanguage(LanguageCode?)
    case started(modelName: String)
    case status(String)
    case text(String)
    case completed(TranslationResult)
}

/// Runs one request end to end: local checks, language detection, policy enforcement,
/// then the provider stream folded into snapshots. It never decides to switch providers.
public struct TranslationCoordinator: Sendable {
    public var detector: LanguageDetector

    public init(detector: LanguageDetector = LanguageDetector()) {
        self.detector = detector
    }

    public func run(
        _ request: TranslationRequest,
        using provider: any TranslationProvider
    ) -> AsyncThrowingStream<CoordinatorEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await execute(request, using: provider, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        _ original: TranslationRequest,
        using provider: any TranslationProvider,
        continuation: AsyncThrowingStream<CoordinatorEvent, any Error>.Continuation
    ) async throws {
        var request = original
        let trimmed = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        // Privacy rule: on-device-only requests never reach a provider that leaves the device.
        if request.networkPolicy == .onDeviceOnly, provider.capabilities.processingLocation.leavesDevice {
            throw TranslationError.policyViolation("This request is limited to on-device processing, but \(provider.displayName) runs \(provider.capabilities.processingLocation.label.lowercased()).")
        }

        if case .automatic = request.sourceLanguage {
            let detected = detector.detect(trimmed)
            request.detectedSourceLanguage = detected
            continuation.yield(.detectedLanguage(detected))
        }

        if let budget = provider.capabilities.contextBudgetTokens {
            let prompt = TranslationPrompt(request: request)
            let estimated = TokenEstimator.estimate(prompt.instructions + prompt.input)
            // Leave room for the answer: a translation is roughly as long as its source.
            let needed = estimated + TokenEstimator.estimate(request.sourceText)
            if needed > budget {
                throw TranslationError.contextTooLong(estimatedTokens: needed, budget: budget)
            }
        }

        var accumulator = StreamedTextAccumulator()
        var lastModelName = provider.displayName
        for try await event in provider.translate(request) {
            try Task.checkCancellation()
            switch event {
            case .started(let modelName):
                lastModelName = modelName
                continuation.yield(.started(modelName: modelName))
            case .status(let status):
                continuation.yield(.status(status))
            case .textDelta, .textSnapshot:
                if accumulator.apply(event) {
                    continuation.yield(.text(accumulator.text))
                }
            case .completed(var result):
                if result.text.isEmpty { result.text = accumulator.text }
                result.text = Self.cleanOutput(result.text)
                if result.modelName.isEmpty { result.modelName = lastModelName }
                continuation.yield(.text(result.text))
                continuation.yield(.completed(result))
                return
            }
        }
        // Provider finished without an explicit completion; synthesize one so the UI settles.
        let result = TranslationResult(
            requestID: request.id,
            text: Self.cleanOutput(accumulator.text),
            providerID: provider.id,
            modelName: lastModelName,
            processingLocation: provider.capabilities.processingLocation
        )
        continuation.yield(.text(result.text))
        continuation.yield(.completed(result))
    }

    /// Strips wrapper tags a model might echo back, and trailing whitespace.
    static func cleanOutput(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["translation", "source_text", "target_text", "output"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            if output.hasPrefix(open), output.hasSuffix(close) {
                output = String(output.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return output
    }
}
