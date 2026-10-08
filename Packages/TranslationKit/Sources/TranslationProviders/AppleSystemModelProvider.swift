import Foundation
import FoundationModels
import TranslationCore

/// Apple's on-device language model via the Foundation Models framework. Availability depends
/// on hardware, region, Apple Intelligence being enabled, and per-language support.
public struct AppleSystemModelProvider: TranslationProvider {
    public static let providerID = "apple.system"
    /// Documented context window of the system model.
    public static let contextWindowTokens = 4096

    public let id = AppleSystemModelProvider.providerID
    public let displayName = "Apple Intelligence"
    public let capabilities = ProviderCapabilities(
        supportsStreaming: true,
        supportsImages: false,
        processingLocation: .onDevice,
        contextBudgetTokens: AppleSystemModelProvider.contextWindowTokens
    )

    public init() {}

    /// Translation is a content transformation; the permissive guardrail profile is the one
    /// Apple documents for that use.
    private var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    public func availability() async -> ProviderAvailability {
        Self.map(model.availability)
    }

    public func supportsLanguage(_ code: LanguageCode) -> Bool {
        model.supportsLocale(code.locale)
    }

    /// Distinct languages, keeping script where it matters (zh-Hans vs zh-Hant) but
    /// collapsing regional variants (en-US, en-GB → en).
    public var supportedLanguages: [LanguageCode] {
        var seen = Set<String>()
        var result: [LanguageCode] = []
        for language in model.supportedLanguages {
            guard let code = language.languageCode?.identifier else { continue }
            let script = language.script?.identifier
            let identifier = (code == "zh", script) == (true, .some("Hant")) ? "zh-Hant"
                : code == "zh" ? "zh-Hans"
                : code
            if seen.insert(identifier).inserted { result.append(LanguageCode(identifier)) }
        }
        return result.sorted { $0.displayName() < $1.displayName() }
    }

    static func map(_ availability: SystemLanguageModel.Availability) -> ProviderAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotSupported("This device does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .needsConfiguration("Turn on Apple Intelligence in System Settings to use the on-device model.")
            case .modelNotReady:
                return .modelNotReady("The on-device model is still downloading or preparing. Try again in a while.")
            @unknown default:
                return .unavailable("Apple Intelligence is not available right now.")
            }
        }
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error, request: request))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: TranslationRequest,
        continuation: AsyncThrowingStream<TranslationEvent, any Error>.Continuation
    ) async throws {
        let model = self.model
        let availability = Self.map(model.availability)
        guard availability.isAvailable else {
            throw TranslationError.modelNotReady(availability.message ?? "Apple Intelligence is unavailable.")
        }
        if !model.supportsLocale(request.targetLanguage.locale) {
            throw TranslationError.unsupportedLanguage(request.targetLanguage.displayName())
        }
        if let source = request.effectiveSourceLanguage, !model.supportsLocale(source.locale) {
            throw TranslationError.unsupportedLanguage(source.displayName())
        }

        let prompt = TranslationPrompt(request: request)
        let session = LanguageModelSession(model: model, instructions: prompt.instructions)
        continuation.yield(.started(modelName: "Apple on-device model"))

        let options = GenerationOptions(temperature: 0.2)
        let stream = session.streamResponse(to: prompt.input, options: options)
        var latest = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            latest = snapshot.content
            continuation.yield(.textSnapshot(latest))
        }
        continuation.yield(.completed(TranslationResult(
            requestID: request.id,
            text: latest,
            providerID: id,
            modelName: "Apple on-device model",
            processingLocation: .onDevice
        )))
    }

    static func map(_ error: any Error, request: TranslationRequest) -> any Error {
        if error is CancellationError { return error }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return TranslationError.contextTooLong(
                    estimatedTokens: TokenEstimator.estimate(request.sourceText) * 2,
                    budget: contextWindowTokens
                )
            case .guardrailViolation:
                return TranslationError.refused("The on-device model's safety guardrail blocked this text.")
            case .unsupportedLanguageOrLocale:
                return TranslationError.unsupportedLanguage(request.targetLanguage.displayName())
            case .rateLimited:
                return TranslationError.rateLimited(retryAfterSeconds: nil)
            case .refusal:
                return TranslationError.refused("The on-device model declined this request.")
            default:
                return TranslationError.providerError(status: 0, message: generation.localizedDescription)
            }
        }
        return error
    }
}
