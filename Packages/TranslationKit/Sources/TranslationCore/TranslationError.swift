import Foundation

/// Unified errors. Adapters map vendor-specific failures onto these so the UI can offer
/// the right recovery action (open settings, retry, switch engine, shorten text).
public enum TranslationError: Error, Hashable, Sendable, LocalizedError {
    case emptyInput
    case missingAPIKey(provider: String)
    case authenticationFailed
    case rateLimited(retryAfterSeconds: Int?)
    case quotaExceeded
    case network(String)
    case invalidResponse(String)
    case refused(String)
    case modelNotReady(String)
    case unsupportedLanguage(String)
    case contextTooLong(estimatedTokens: Int, budget: Int)
    case policyViolation(String)
    case providerError(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "There is nothing to translate."
        case .missingAPIKey(let provider):
            "\(provider) needs an API key."
        case .authenticationFailed:
            "The API key was rejected."
        case .rateLimited(let seconds):
            if let seconds { "Rate limited. Try again in \(seconds) seconds." } else { "Rate limited. Try again shortly." }
        case .quotaExceeded:
            "The account's quota or credit is exhausted."
        case .network(let message):
            "Network error: \(message)"
        case .invalidResponse(let message):
            "Unexpected response: \(message)"
        case .refused(let message):
            "The model declined to translate this: \(message)"
        case .modelNotReady(let message):
            message
        case .unsupportedLanguage(let language):
            "This engine does not support \(language)."
        case .contextTooLong(let estimated, let budget):
            "The text is too long for this engine (about \(estimated) tokens; limit \(budget))."
        case .policyViolation(let message):
            message
        case .providerError(let status, let message):
            "The service returned an error (\(status)): \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missingAPIKey, .authenticationFailed:
            "Open Settings to add or update the key."
        case .rateLimited, .quotaExceeded, .network:
            "Retry, or switch to another engine."
        case .contextTooLong:
            "Split the text into smaller parts, or choose an engine with a larger context."
        case .refused, .policyViolation:
            "Try another engine. The original text was kept."
        case .unsupportedLanguage:
            "Pick a different target language or engine."
        case .modelNotReady:
            "Wait for the model to finish preparing, or choose another engine."
        case .emptyInput, .invalidResponse, .providerError:
            nil
        }
    }

    /// True when the user may reasonably retry without changing anything.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .network, .modelNotReady: true
        case .providerError(let status, _): status >= 500
        default: false
        }
    }
}
