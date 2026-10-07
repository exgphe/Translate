import Foundation

/// Where inference ran. Shown to the user next to every result.
public enum ProcessingLocation: String, Hashable, Codable, Sendable {
    case onDevice
    case localServer
    case cloud

    public var label: String {
        switch self {
        case .onDevice: "On device"
        case .localServer: "Local server"
        case .cloud: "Cloud"
        }
    }

    public var leavesDevice: Bool { self != .onDevice }
}

public struct TokenUsage: Hashable, Codable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct TranslationResult: Hashable, Codable, Sendable {
    public var requestID: UUID
    public var text: String
    public var providerID: String
    public var modelName: String
    public var processingLocation: ProcessingLocation
    public var usage: TokenUsage?
    public var finishedAt: Date

    public init(
        requestID: UUID,
        text: String,
        providerID: String,
        modelName: String,
        processingLocation: ProcessingLocation,
        usage: TokenUsage? = nil,
        finishedAt: Date = .now
    ) {
        self.requestID = requestID
        self.text = text
        self.providerID = providerID
        self.modelName = modelName
        self.processingLocation = processingLocation
        self.usage = usage
        self.finishedAt = finishedAt
    }
}

/// Events a provider emits for one request. Adapters normalize every vendor's streaming
/// style into either deltas or full snapshots so the UI never duplicates text.
public enum TranslationEvent: Hashable, Sendable {
    case started(modelName: String)
    case status(String)
    /// Append this fragment to the text accumulated so far.
    case textDelta(String)
    /// Replace the accumulated text with this complete snapshot.
    case textSnapshot(String)
    case completed(TranslationResult)
}
