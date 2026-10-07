import Foundation

/// A BCP-47 language identifier such as `en`, `zh-Hans`, or `pt-BR`.
public struct LanguageCode: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public var id: String { identifier }
    public var description: String { identifier }
    public var locale: Locale { Locale(identifier: identifier) }

    /// Localized display name for UI, e.g. "Chinese (Simplified)" or "简体中文".
    public func displayName(in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// English name used inside prompts so every model sees the same wording.
    public var englishName: String {
        switch identifier {
        case "zh-Hans", "zh-CN": return "Simplified Chinese"
        case "zh-Hant", "zh-TW", "zh-HK": return "Traditional Chinese"
        case "pt-BR": return "Brazilian Portuguese"
        case "pt-PT": return "European Portuguese"
        default: return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
        }
    }

    public static let english = LanguageCode("en")
    public static let simplifiedChinese = LanguageCode("zh-Hans")
    public static let traditionalChinese = LanguageCode("zh-Hant")
    public static let japanese = LanguageCode("ja")
    public static let korean = LanguageCode("ko")

    /// Target languages offered in the picker. Users can still type any identifier.
    public static let commonTargets: [LanguageCode] = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko",
        "fr", "de", "es", "it", "pt-BR", "pt-PT", "nl", "sv", "da", "nb", "fi", "pl", "cs", "uk", "ru",
        "tr", "ar", "he", "hi", "th", "vi", "id", "ms",
    ].map(LanguageCode.init)
}

/// Where the source language comes from: local detection or an explicit user choice.
public enum SourceLanguage: Hashable, Codable, Sendable {
    case automatic
    case explicit(LanguageCode)

    public var explicitCode: LanguageCode? {
        if case .explicit(let code) = self { return code }
        return nil
    }
}
