import Foundation

public struct ProviderCapabilities: Hashable, Sendable {
    public var supportsStreaming: Bool
    public var supportsImages: Bool
    public var processingLocation: ProcessingLocation
    /// Approximate prompt budget in tokens, when the model has a hard limit worth checking locally.
    public var contextBudgetTokens: Int?

    public init(
        supportsStreaming: Bool,
        supportsImages: Bool,
        processingLocation: ProcessingLocation,
        contextBudgetTokens: Int? = nil
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsImages = supportsImages
        self.processingLocation = processingLocation
        self.contextBudgetTokens = contextBudgetTokens
    }
}

public enum ProviderAvailability: Hashable, Sendable {
    case available
    case needsConfiguration(String)
    case modelNotReady(String)
    case deviceNotSupported(String)
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .available: nil
        case .needsConfiguration(let m), .modelNotReady(let m), .deviceNotSupported(let m), .unavailable(let m): m
        }
    }
}

/// The domain interface every engine implements. It speaks translation tasks, not vendor
/// sessions, so the core never depends on a particular SDK or OS version.
public protocol TranslationProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }

    func availability() async -> ProviderAvailability

    /// Streams events for the request. Cancelling the consuming task must cancel the
    /// underlying inference or network work.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error>
}
