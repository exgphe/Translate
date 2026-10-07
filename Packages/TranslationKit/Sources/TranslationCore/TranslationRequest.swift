import Foundation

/// What the model is asked to do with the source text.
public enum TranslationMode: Hashable, Codable, Sendable {
    /// Produce the translation only.
    case translate
    /// Explain an existing translation; `focus` narrows it to a phrase the user picked.
    case explain(focus: String?)
}

/// Whether the content may leave the device. Enforced by the coordinator, not by the UI.
public enum NetworkPolicy: String, Hashable, Codable, Sendable {
    case allowCloud
    case onDeviceOnly
}

public struct GlossaryEntry: Hashable, Codable, Sendable {
    public var term: String
    public var translation: String

    public init(term: String, translation: String) {
        self.term = term
        self.translation = translation
    }
}

/// An immutable snapshot of one translation task. The `id` lets the UI discard late events
/// from a superseded request.
public struct TranslationRequest: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var sourceText: String
    public var sourceLanguage: SourceLanguage
    /// Filled in by the coordinator when `sourceLanguage` is `.automatic`.
    public var detectedSourceLanguage: LanguageCode?
    public var targetLanguage: LanguageCode
    public var mode: TranslationMode
    /// Background the user supplied: audience, tone, domain, what a name refers to, etc.
    public var context: String?
    public var glossary: [GlossaryEntry]
    /// Existing translation, required for `.explain`.
    public var priorTranslation: String?
    public var networkPolicy: NetworkPolicy
    public var promptVersion: String

    public init(
        id: UUID = UUID(),
        sourceText: String,
        sourceLanguage: SourceLanguage = .automatic,
        detectedSourceLanguage: LanguageCode? = nil,
        targetLanguage: LanguageCode,
        mode: TranslationMode = .translate,
        context: String? = nil,
        glossary: [GlossaryEntry] = [],
        priorTranslation: String? = nil,
        networkPolicy: NetworkPolicy = .allowCloud,
        promptVersion: String = TranslationPrompt.version
    ) {
        self.id = id
        self.sourceText = sourceText
        self.sourceLanguage = sourceLanguage
        self.detectedSourceLanguage = detectedSourceLanguage
        self.targetLanguage = targetLanguage
        self.mode = mode
        self.context = context
        self.glossary = glossary
        self.priorTranslation = priorTranslation
        self.networkPolicy = networkPolicy
        self.promptVersion = promptVersion
    }

    /// The language the prompt should name as the source, if any is known.
    public var effectiveSourceLanguage: LanguageCode? {
        sourceLanguage.explicitCode ?? detectedSourceLanguage
    }
}
