import Foundation
import TranslationCore
#if canImport(Translation) && !os(visionOS)
import Translation
#endif

/// Translates one caption line at a time.
public protocol CaptionTranslating: Sendable {
    var displayName: String { get }
    var processingLocation: ProcessingLocation { get }
    /// Fast enough to also translate the phrase still being recognized.
    var translatesVolatileText: Bool { get }
    func translate(_ text: String, previousLines: [String]) async throws -> String
}

/// Uses any translation engine of the app (Apple Intelligence, Anthropic, OpenAI-compatible).
/// Slower than Apple Translation but understands context.
public struct ProviderCaptionTranslator: CaptionTranslating {
    public let provider: any TranslationProvider
    public let sourceLanguage: LanguageCode?
    public let targetLanguage: LanguageCode
    public let networkPolicy: NetworkPolicy

    public init(provider: any TranslationProvider, sourceLanguage: LanguageCode?, targetLanguage: LanguageCode, networkPolicy: NetworkPolicy) {
        self.provider = provider
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.networkPolicy = networkPolicy
    }

    public var displayName: String { provider.displayName }
    public var processingLocation: ProcessingLocation { provider.capabilities.processingLocation }
    public var translatesVolatileText: Bool { false }

    public func translate(_ text: String, previousLines: [String]) async throws -> String {
        let request = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguage.map { .explicit($0) } ?? .automatic,
            targetLanguage: targetLanguage,
            context: Self.context(previousLines: previousLines),
            networkPolicy: networkPolicy
        )
        var translation = ""
        for try await event in TranslationCoordinator().run(request, using: provider) {
            if case .completed(let result) = event { translation = result.text }
        }
        return translation
    }

    static func context(previousLines: [String]) -> String {
        var lines = [
            "This is one line of live subtitles produced by automatic speech recognition, so it may contain recognition errors or start mid-sentence.",
            "Translate only this line. Do not add, complete, or summarize anything.",
        ]
        if !previousLines.isEmpty {
            lines.append("The preceding subtitle lines, for reference only:")
            lines.append(contentsOf: previousLines)
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(Translation) && !os(visionOS)
/// Apple's on-device Translation framework.
///
/// Low-latency models are a separate download from the standard ones: a pair can be installed
/// for the standard strategy and still fail with `notInstalled` in low-latency mode. Check
/// `readiness` and create the translator with the strategy it reports.
public final class AppleCaptionTranslator: CaptionTranslating, @unchecked Sendable {
    public enum Readiness: Equatable, Sendable {
        /// Low-latency models installed: fast enough for the phrase still being spoken.
        case lowLatency
        /// Only the standard models are installed: works, but slower (0.5–3 s per sentence).
        case standard
        /// Supported, but nothing usable is downloaded yet.
        case needsDownload
        case unsupported
    }

    public let displayName: String
    public let processingLocation = ProcessingLocation.onDevice
    public let translatesVolatileText: Bool
    /// The framework's `translate` is `@concurrent`; the session itself is immutable after init
    /// and accepts overlapping requests, so it is shared across calls.
    nonisolated(unsafe) private let session: TranslationSession

    public init(source: Locale.Language, target: Locale.Language, lowLatency: Bool) {
        session = TranslationSession(installedSource: source, target: target, preferredStrategy: lowLatency ? .lowLatency : .highFidelity)
        translatesVolatileText = lowLatency
        displayName = lowLatency ? "Apple Translation" : "Apple Translation (standard models)"
    }

    public func translate(_ text: String, previousLines: [String]) async throws -> String {
        do {
            return try await session.translate(text).targetText
        } catch let error as Translation.TranslationError {
            // Every case's description is "Unable to Translate"; the reason is the useful part.
            throw LiveCaptionsError.translationFailed(error.failureReason ?? error.errorDescription ?? "Unknown error")
        }
    }

    public static func readiness(source: Locale.Language, target: Locale.Language) async -> Readiness {
        let fast = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
        if fast == .installed { return .lowLatency }
        let standard = await LanguageAvailability().status(from: source, to: target)
        if standard == .installed { return .standard }
        if fast == .supported || standard == .supported { return .needsDownload }
        return .unsupported
    }
}
#endif
