import Foundation
import Observation
import TranslationCore

/// User preferences and non-secret engine configuration, persisted in UserDefaults.
/// Secrets live in `KeychainStore`.
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    private let sharedTranslationDefaults: UserDefaults?

    /// Only translation preferences are shared. Clipboard state and history stay in the app.
    static var translationServiceDefaults: UserDefaults? {
        #if os(iOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CaptionFeedAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
        #else
        return nil
        #endif
    }

    private enum Key {
        static let selectedEngineID = "engine.selected"
        static let targetLanguage = "language.target"
        static let sourceLanguage = "language.source"
        static let historyEnabled = "history.enabled"
        static let anthropicModel = "anthropic.model"
        static let anthropicEffort = "anthropic.effort"
        static let openAIName = "openai.name"
        static let openAIBaseURL = "openai.baseURL"
        static let openAIModel = "openai.model"
        static let onDeviceOnly = "privacy.onDeviceOnly"
        static let autoPaste = "clipboard.autoPaste"
        static let autoPasteTranslates = "clipboard.autoPasteTranslates"
        static let lastPasteboardChangeCount = "clipboard.lastChangeCount"
    }

    var selectedEngineID: String {
        didSet { persistTranslation(selectedEngineID, forKey: Key.selectedEngineID) }
    }

    var targetLanguage: LanguageCode {
        didSet { persistTranslation(targetLanguage.identifier, forKey: Key.targetLanguage) }
    }

    /// Empty string means automatic detection.
    var sourceLanguageIdentifier: String {
        didSet { persistTranslation(sourceLanguageIdentifier, forKey: Key.sourceLanguage) }
    }

    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// When on, requests are refused before reaching any engine that leaves the device.
    var onDeviceOnly: Bool {
        didSet { persistTranslation(onDeviceOnly, forKey: Key.onDeviceOnly) }
    }

    /// Paste whatever another app copies, checked while this app is open. Off by default.
    var autoPasteEnabled: Bool {
        didSet { defaults.set(autoPasteEnabled, forKey: Key.autoPaste) }
    }

    /// Start translating right after an automatic paste.
    var autoPasteTranslates: Bool {
        didSet { defaults.set(autoPasteTranslates, forKey: Key.autoPasteTranslates) }
    }

    /// Last pasteboard change the app has handled. Persisted so copying something and then
    /// opening the app counts as a change.
    @ObservationIgnored var lastPasteboardChangeCount: Int {
        didSet { defaults.set(lastPasteboardChangeCount, forKey: Key.lastPasteboardChangeCount) }
    }

    var anthropicModel: String {
        didSet { persistTranslation(anthropicModel, forKey: Key.anthropicModel) }
    }

    var anthropicEffort: String {
        didSet { persistTranslation(anthropicEffort, forKey: Key.anthropicEffort) }
    }

    var openAIDisplayName: String {
        didSet { persistTranslation(openAIDisplayName, forKey: Key.openAIName) }
    }

    var openAIBaseURL: String {
        didSet { persistTranslation(openAIBaseURL, forKey: Key.openAIBaseURL) }
    }

    var openAIModel: String {
        didSet { persistTranslation(openAIModel, forKey: Key.openAIModel) }
    }

    init(defaults: UserDefaults = .standard, sharedTranslationDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.sharedTranslationDefaults = sharedTranslationDefaults
        selectedEngineID = defaults.string(forKey: Key.selectedEngineID) ?? ""
        targetLanguage = LanguageCode(defaults.string(forKey: Key.targetLanguage) ?? Self.defaultTargetLanguage().identifier)
        sourceLanguageIdentifier = defaults.string(forKey: Key.sourceLanguage) ?? ""
        historyEnabled = defaults.object(forKey: Key.historyEnabled) as? Bool ?? true
        onDeviceOnly = defaults.bool(forKey: Key.onDeviceOnly)
        autoPasteEnabled = defaults.bool(forKey: Key.autoPaste)
        autoPasteTranslates = defaults.object(forKey: Key.autoPasteTranslates) as? Bool ?? true
        lastPasteboardChangeCount = defaults.object(forKey: Key.lastPasteboardChangeCount) as? Int ?? -1
        anthropicModel = defaults.string(forKey: Key.anthropicModel) ?? "claude-opus-5-5"
        anthropicEffort = defaults.string(forKey: Key.anthropicEffort) ?? "low"
        openAIDisplayName = defaults.string(forKey: Key.openAIName) ?? "OpenAI-compatible"
        openAIBaseURL = defaults.string(forKey: Key.openAIBaseURL) ?? "https://api.openai.com/v1"
        openAIModel = defaults.string(forKey: Key.openAIModel) ?? ""
        publishTranslationPreferences()
    }

    private func persistTranslation(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        sharedTranslationDefaults?.set(value, forKey: key)
    }

    private func publishTranslationPreferences() {
        guard let sharedTranslationDefaults else { return }
        let values: [String: Any] = [
            Key.selectedEngineID: selectedEngineID,
            Key.targetLanguage: targetLanguage.identifier,
            Key.sourceLanguage: sourceLanguageIdentifier,
            Key.onDeviceOnly: onDeviceOnly,
            Key.anthropicModel: anthropicModel,
            Key.anthropicEffort: anthropicEffort,
            Key.openAIName: openAIDisplayName,
            Key.openAIBaseURL: openAIBaseURL,
            Key.openAIModel: openAIModel,
        ]
        for (key, value) in values { sharedTranslationDefaults.set(value, forKey: key) }
    }

    var sourceLanguage: SourceLanguage {
        get { sourceLanguageIdentifier.isEmpty ? .automatic : .explicit(LanguageCode(sourceLanguageIdentifier)) }
        set { sourceLanguageIdentifier = newValue.explicitCode?.identifier ?? "" }
    }

    var networkPolicy: NetworkPolicy { onDeviceOnly ? .onDeviceOnly : .allowCloud }

    /// First launch: translate into the user's own language unless that is English, then
    /// fall back to English → Simplified Chinese which matches the maintainer's main use.
    static func defaultTargetLanguage() -> LanguageCode {
        if let preferred = Locale.preferredLanguages.first {
            let locale = Locale(identifier: preferred)
            if let code = locale.language.languageCode?.identifier, code != "en" {
                if code == "zh" {
                    return locale.language.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
                }
                return LanguageCode(code)
            }
        }
        return .simplifiedChinese
    }
}
