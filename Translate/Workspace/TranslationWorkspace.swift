import CoreGraphics
import Foundation
import ImagePipeline
import Observation
import SwiftData
import TranslationCore

/// UI state for the translation screen. Owns the running task and guarantees that a
/// superseded request can never overwrite newer results.
@Observable
@MainActor
final class TranslationWorkspace {
    enum Phase: Equatable {
        case idle
        case running
        case completed
        case failed(message: String, suggestion: String?)

        var isRunning: Bool { self == .running }
    }

    struct ImageAttachment {
        var image: ImportedImage
        var document: RecognizedDocument?
        var phase: Phase
    }

    let settings: AppSettings
    let registry: EngineRegistry
    private let modelContext: ModelContext?
    private let coordinator = TranslationCoordinator()
    private let recognizer = VisionTextRecognizer()

    // Input
    var sourceText: String = ""
    var context: String = ""
    private(set) var attachment: ImageAttachment?

    // Output
    private(set) var detectedLanguage: LanguageCode?
    private(set) var translatedText: String = ""
    private(set) var phase: Phase = .idle
    private(set) var statusMessage: String?
    private(set) var lastResult: TranslationResult?
    private(set) var lastRequest: TranslationRequest?

    // Explanation
    var explanationFocus: String = ""
    private(set) var explanation: String = ""
    private(set) var explanationPhase: Phase = .idle

    // Presentation flags
    var isImportingImage = false
    var isPickingPhoto = false
    var isShowingContext = false
    var isShowingExplain = false
    var isShowingSettings = false
    var isShowingHistory = false

    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var explanationTask: Task<Void, Never>?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?

    init(settings: AppSettings, registry: EngineRegistry, modelContext: ModelContext?) {
        self.settings = settings
        self.registry = registry
        self.modelContext = modelContext
    }

    // MARK: - Languages

    var sourceLanguage: SourceLanguage {
        get { settings.sourceLanguage }
        set { settings.sourceLanguage = newValue }
    }

    var targetLanguage: LanguageCode {
        get { settings.targetLanguage }
        set { settings.targetLanguage = newValue }
    }

    /// Swapping is only reliable when the source language is known.
    var canSwapLanguages: Bool {
        (sourceLanguage.explicitCode ?? detectedLanguage) != nil
    }

    func swapLanguages() {
        guard let source = sourceLanguage.explicitCode ?? detectedLanguage else { return }
        let target = targetLanguage
        sourceLanguage = .explicit(target)
        targetLanguage = source
        if phase == .completed, !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
            phase = .idle
            lastResult = nil
        }
    }

    // MARK: - Translate

    var canTranslate: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isRunning
    }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let engine = registry.selectedEngine, let provider = registry.makeProvider(id: engine.id) else {
            phase = .failed(message: "No translation engine is configured.", suggestion: "Open Settings to set up Apple Intelligence or a cloud service.")
            return
        }
        let request = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            context: context.isEmpty ? nil : context,
            networkPolicy: settings.networkPolicy
        )
        start(request, provider: provider)
    }

    func retry() {
        guard let request = lastRequest, let engine = registry.selectedEngine,
              let provider = registry.makeProvider(id: engine.id) else {
            translate()
            return
        }
        start(TranslationRequest(
            sourceText: request.sourceText,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            context: request.context,
            networkPolicy: settings.networkPolicy
        ), provider: provider)
    }

    private func start(_ request: TranslationRequest, provider: any TranslationProvider) {
        cancelTranslation()
        activeRequestID = request.id
        lastRequest = request
        lastResult = nil
        translatedText = ""
        explanation = ""
        explanationPhase = .idle
        statusMessage = nil
        phase = .running
        if case .automatic = request.sourceLanguage { detectedLanguage = nil }

        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in coordinator.run(request, using: provider) {
                    guard activeRequestID == request.id else { return }
                    apply(event, for: request)
                }
                guard activeRequestID == request.id else { return }
                if phase == .running { phase = .completed }
            } catch is CancellationError {
                guard activeRequestID == request.id else { return }
                phase = translatedText.isEmpty ? .idle : .completed
                statusMessage = translatedText.isEmpty ? nil : "Stopped. Partial result shown."
            } catch {
                guard activeRequestID == request.id else { return }
                fail(error)
            }
        }
    }

    private func apply(_ event: CoordinatorEvent, for request: TranslationRequest) {
        switch event {
        case .detectedLanguage(let language):
            detectedLanguage = language
        case .started(let modelName):
            statusMessage = modelName
        case .status(let status):
            statusMessage = status
        case .text(let text):
            translatedText = text
        case .completed(let result):
            translatedText = result.text
            lastResult = result
            phase = .completed
            statusMessage = nil
            saveHistory(request: request, result: result)
        }
    }

    private func fail(_ error: any Error) {
        let message: String
        let suggestion: String?
        if let translationError = error as? TranslationError {
            message = translationError.errorDescription ?? "Translation failed."
            suggestion = translationError.recoverySuggestion
        } else {
            message = error.localizedDescription
            suggestion = nil
        }
        phase = .failed(message: message, suggestion: suggestion)
        statusMessage = nil
    }

    func stop() {
        cancelTranslation()
        if phase == .running {
            phase = translatedText.isEmpty ? .idle : .completed
            statusMessage = translatedText.isEmpty ? nil : "Stopped. Partial result shown."
        }
        if explanationPhase == .running {
            explanationTask?.cancel()
            explanationPhase = explanation.isEmpty ? .idle : .completed
        }
    }

    private func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        activeRequestID = nil
    }

    var lastError: (message: String, suggestion: String?)? {
        if case .failed(let message, let suggestion) = phase { return (message, suggestion) }
        return nil
    }

    // MARK: - Explain

    func explain() {
        guard let base = lastRequest, !translatedText.isEmpty,
              let engine = registry.selectedEngine, let provider = registry.makeProvider(id: engine.id) else { return }
        explanationTask?.cancel()
        let focus = explanationFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TranslationRequest(
            sourceText: base.sourceText,
            sourceLanguage: base.sourceLanguage,
            detectedSourceLanguage: detectedLanguage,
            targetLanguage: base.targetLanguage,
            mode: .explain(focus: focus.isEmpty ? nil : focus),
            context: base.context,
            priorTranslation: translatedText,
            networkPolicy: settings.networkPolicy
        )
        explanation = ""
        explanationPhase = .running
        explanationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in coordinator.run(request, using: provider) {
                    if case .text(let text) = event { explanation = text }
                }
                explanationPhase = .completed
            } catch is CancellationError {
                explanationPhase = explanation.isEmpty ? .idle : .completed
            } catch {
                let message = (error as? TranslationError)?.errorDescription ?? error.localizedDescription
                explanationPhase = .failed(message: message, suggestion: nil)
            }
        }
    }

    // MARK: - Images

    /// - Parameter translateWhenDone: start translating once OCR has produced text.
    func importImage(data: Data, translateWhenDone: Bool = false) {
        ocrTask?.cancel()
        do {
            let image = try ImageLoader.load(data)
            attachment = ImageAttachment(image: image, document: nil, phase: .running)
        } catch {
            attachment = nil
            phase = .failed(message: error.localizedDescription, suggestion: "Try a PNG, JPEG, HEIC, or TIFF image.")
            return
        }
        let recognizer = self.recognizer
        guard let image = attachment?.image else { return }
        ocrTask = Task { [weak self] in
            do {
                let document = try await recognizer.recognize(image, languages: [])
                guard let self, !Task.isCancelled else { return }
                attachment?.document = document
                if document.isEmpty {
                    attachment?.phase = .failed(message: "No text was found in the image.", suggestion: "Crop closer to the text or type it in.")
                } else {
                    attachment?.phase = .completed
                    sourceText = document.text
                    if settings.sourceLanguage.explicitCode == nil { detectedLanguage = nil }
                    if translateWhenDone { translate() }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                attachment?.phase = .failed(message: error.localizedDescription, suggestion: nil)
            }
        }
    }

    func importImage(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            importImage(data: try Data(contentsOf: url))
        } catch {
            phase = .failed(message: error.localizedDescription, suggestion: nil)
        }
    }

    func removeImage() {
        ocrTask?.cancel()
        attachment = nil
    }

    // MARK: - Clipboard

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        Pasteboard.copy(translatedText)
    }

    /// Handles the system Paste button: replace the source and translate in one step.
    func paste(_ items: [PastedContent]) {
        guard let item = items.first else { return }
        switch item {
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sourceText = text
            removeImage()
            translate()
        case .image(let data):
            importImage(data: data, translateWhenDone: true)
        }
    }

    /// Called periodically while the app is open. Reads the pasteboard only after its change
    /// count moves, and ignores what this app copied itself or what is already shown.
    func checkClipboardForAutoPaste() {
        guard settings.autoPasteEnabled else { return }
        let count = Pasteboard.changeCount
        guard count != settings.lastPasteboardChangeCount else { return }
        settings.lastPasteboardChangeCount = count
        guard count != Pasteboard.ownChangeCount else { return }

        if Pasteboard.hasText {
            guard let text = Pasteboard.readString()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text != sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                  text != translatedText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            sourceText = text
            removeImage()
            if settings.autoPasteTranslates { translate() }
        } else if Pasteboard.hasImage, let data = Pasteboard.readImageData() {
            importImage(data: data, translateWhenDone: settings.autoPasteTranslates)
        }
    }

    func pasteAndTranslate() {
        if let data = Pasteboard.readImageData() {
            importImage(data: data)
            return
        }
        if let text = Pasteboard.readString(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sourceText = text
            removeImage()
            translate()
        }
    }

    // MARK: - Session

    func clear() {
        cancelTranslation()
        explanationTask?.cancel()
        removeImage()
        sourceText = ""
        translatedText = ""
        explanation = ""
        explanationPhase = .idle
        detectedLanguage = nil
        lastResult = nil
        lastRequest = nil
        statusMessage = nil
        phase = .idle
    }

    func load(_ entry: HistoryEntry) {
        cancelTranslation()
        explanationTask?.cancel()
        removeImage()
        sourceText = entry.sourceText
        translatedText = entry.translatedText
        context = entry.context ?? ""
        targetLanguage = entry.targetLanguageCode
        detectedLanguage = entry.sourceLanguageCode
        explanation = ""
        explanationPhase = .idle
        statusMessage = nil
        phase = .completed
        let request = TranslationRequest(
            id: entry.id,
            sourceText: entry.sourceText,
            sourceLanguage: sourceLanguage,
            detectedSourceLanguage: entry.sourceLanguageCode,
            targetLanguage: entry.targetLanguageCode,
            context: entry.context,
            promptVersion: entry.promptVersion
        )
        lastRequest = request
        lastResult = TranslationResult(
            requestID: entry.id,
            text: entry.translatedText,
            providerID: entry.engineID,
            modelName: entry.modelName,
            processingLocation: entry.location,
            finishedAt: entry.createdAt
        )
    }

    // MARK: - History

    private func saveHistory(request: TranslationRequest, result: TranslationResult) {
        guard settings.historyEnabled, let modelContext, !result.text.isEmpty else { return }
        modelContext.insert(HistoryEntry(request: request, result: result))
        try? modelContext.save()
    }
}
