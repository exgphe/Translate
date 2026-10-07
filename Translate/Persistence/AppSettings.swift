import Foundation
import Observation
import TranslationCore

/// User preferences and non-secret engine configuration, persisted in UserDefaults.
/// Secrets live in `KeychainStore`.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

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
    }

    var selectedEngineID: String {
        didSet { defaults.set(selectedEngineID, forKey: Key.selectedEngineID) }
    }

    var targetLanguage: LanguageCode {
        didSet { defaults.set(targetLanguage.identifier, forKey: Key.targetLanguage) }
    }

    /// Empty string means automatic detection.
    var sourceLanguageIdentifier: String {
        didSet { defaults.set(sourceLanguageIdentifier, forKey: Key.sourceLanguage) }
    }

    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// When on, requests are refused before reaching any engine that leaves the device.
    var onDeviceOnly: Bool {
        didSet { defaults.set(onDeviceOnly, forKey: Key.onDeviceOnly) }
    }

    var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: Key.anthropicModel) }
    }

    var anthropicEffort: String {
        didSet { defaults.set(anthropicEffort, forKey: Key.anthropicEffort) }
    }

    var openAIDisplayName: String {
        didSet { defaults.set(openAIDisplayName, forKey: Key.openAIName) }
    }

    var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: Key.openAIBaseURL) }
    }

    var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Key.openAIModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedEngineID = defaults.string(forKey: Key.selectedEngineID) ?? ""
        targetLanguage = LanguageCode(defaults.string(forKey: Key.targetLanguage) ?? Self.defaultTargetLanguage().identifier)
        sourceLanguageIdentifier = defaults.string(forKey: Key.sourceLanguage) ?? ""
        historyEnabled = defaults.object(forKey: Key.historyEnabled) as? Bool ?? true
        onDeviceOnly = defaults.bool(forKey: Key.onDeviceOnly)
        anthropicModel = defaults.string(forKey: Key.anthropicModel) ?? "claude-opus-5-5"
        anthropicEffort = defaults.string(forKey: Key.anthropicEffort) ?? "low"
        openAIDisplayName = defaults.string(forKey: Key.openAIName) ?? "OpenAI-compatible"
        openAIBaseURL = defaults.string(forKey: Key.openAIBaseURL) ?? "https://api.openai.com/v1"
        openAIModel = defaults.string(forKey: Key.openAIModel) ?? ""
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
