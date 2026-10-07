import Foundation

/// Folds delta and snapshot events into one growing string.
public struct StreamedTextAccumulator: Hashable, Sendable {
    public private(set) var text: String = ""

    public init() {}

    /// Applies the event. Returns true when the accumulated text changed.
    @discardableResult
    public mutating func apply(_ event: TranslationEvent) -> Bool {
        switch event {
        case .textDelta(let delta):
            guard !delta.isEmpty else { return false }
            text.append(delta)
            return true
        case .textSnapshot(let snapshot):
            guard snapshot != text else { return false }
            text = snapshot
            return true
        case .started, .status, .completed:
            return false
        }
    }
}
