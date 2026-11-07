import Foundation
import Observation
import TranslationCore

/// One system selection, with no history, clipboard access, or dependency on AppModel.
@Observable
@MainActor
final class SelectedTextTranslation {
    struct RequestIdentity: Hashable {
        let input: String
        let source: SourceLanguage
        let target: LanguageCode
        let engineID: String
        let networkPolicy: NetworkPolicy
    }

    var input = "" { didSet { if input != oldValue { invalidate() } } }
    var sourceLanguage: SourceLanguage = .automatic {
        didSet { if sourceLanguage != oldValue { invalidate() } }
    }
    var targetLanguage: LanguageCode = .simplifiedChinese {
        didSet { if targetLanguage != oldValue { invalidate() } }
    }
    var engineID = "" { didSet { if engineID != oldValue { invalidate() } } }
    var networkPolicy: NetworkPolicy = .allowCloud {
        didSet { if networkPolicy != oldValue { invalidate() } }
    }

    private(set) var text = ""
    private(set) var isTranslating = false
    private(set) var status: String?
    private(set) var error: String?
    private(set) var result: TranslationResult?
    private(set) var detectedLanguage: LanguageCode?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var automaticRequest: RequestIdentity?

    var requestIdentity: RequestIdentity {
        RequestIdentity(input: input, source: sourceLanguage, target: targetLanguage,
                        engineID: engineID, networkPolicy: networkPolicy)
    }

    var completedText: String? {
        guard !isTranslating, let result, !result.text.isEmpty else { return nil }
        return result.text
    }

    /// View tasks can run again after layout changes. Only a changed selection or
    /// configuration starts a new request; stopping or a failure requires an explicit retry.
    func translateAutomatically(using provider: any TranslationProvider) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.id == engineID, automaticRequest != requestIdentity else { return }
        let identity = requestIdentity
        translate(using: provider)
        automaticRequest = identity
    }

    func translate(using provider: any TranslationProvider) {
        invalidate()
        guard provider.id == engineID else { return }
        let request = TranslationRequest(
            sourceText: input, sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage, networkPolicy: networkPolicy
        )
        let generation = generation
        isTranslating = true
        task = Task { [weak self] in
            do {
                let availability = await provider.availability()
                try Task.checkCancellation()
                guard availability.isAvailable else {
                    throw TranslationError.modelNotReady(availability.message ?? "Open Translate to configure this engine.")
                }
                for try await event in TranslationCoordinator().run(request, using: provider) {
                    try Task.checkCancellation()
                    guard let self, self.generation == generation else { return }
                    switch event {
                    case .started(let modelName): self.status = modelName
                    case .status(let message): self.status = message
                    case .text(let text): self.text = text
                    case .completed(let result):
                        self.result = result
                        self.text = result.text
                    case .detectedLanguage(let language): self.detectedLanguage = language
                    }
                }
                guard let self, self.generation == generation else { return }
                self.isTranslating = false
                self.task = nil
            } catch {
                guard let self, self.generation == generation else { return }
                self.isTranslating = false
                self.result = nil
                self.error = error is CancellationError ? nil : error.localizedDescription
                self.task = nil
            }
        }
    }

    func cancel() {
        // Partial output can still be read, but is never eligible for replacement.
        generation = UUID()
        task?.cancel()
        task = nil
        isTranslating = false
        result = nil
        status = nil
    }

    func invalidate() {
        cancel()
        text = ""
        error = nil
        detectedLanguage = nil
        automaticRequest = nil
    }
}
