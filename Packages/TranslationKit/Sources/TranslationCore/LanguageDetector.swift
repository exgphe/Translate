import Foundation
import NaturalLanguage

/// On-device language identification. Never sends text anywhere.
public struct LanguageDetector: Sendable {
    public init() {}

    /// Returns the dominant language, or nil when the text is too short or ambiguous.
    public func detect(_ text: String) -> LanguageCode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        // Very short inputs produce low-confidence guesses; treat them as unknown so the
        // prompt says "auto-detect" instead of asserting a wrong language.
        guard confidence >= 0.4 || trimmed.count >= 12 else { return nil }
        return LanguageCode(dominant.rawValue)
    }
}
