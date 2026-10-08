import Foundation

/// One finalized caption: what was said, and its translation once it arrives.
public struct CaptionLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public var original: String
    public var translation: String?
    public var translationFailed = false
    public let finalizedAt: Date

    public init(id: Int, original: String, translation: String? = nil, finalizedAt: Date = .now) {
        self.id = id
        self.original = original
        self.translation = translation
        self.finalizedAt = finalizedAt
    }
}

/// Folds streaming recognition into captions: finalized lines plus the phrase still being
/// recognized ("volatile"), each with an optional translation.
public struct CaptionTimeline: Hashable, Sendable {
    public private(set) var lines: [CaptionLine] = []
    /// Recognition of the phrase in progress. Replaced on every update.
    public private(set) var volatileOriginal = ""
    /// Provisional translation of (an earlier version of) the volatile phrase.
    public private(set) var volatileTranslation: String?
    public let maximumLines: Int
    private var nextID = 0

    public init(maximumLines: Int = 300) {
        self.maximumLines = maximumLines
    }

    public mutating func updateVolatile(_ text: String) {
        volatileOriginal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if volatileOriginal.isEmpty { volatileTranslation = nil }
    }

    /// Accepts a provisional translation only while that phrase is still on screen.
    public mutating func setVolatileTranslation(_ translation: String, source: String) {
        guard !volatileOriginal.isEmpty, volatileOriginal.hasPrefix(source) || source.hasPrefix(volatileOriginal) else { return }
        volatileTranslation = translation
    }

    /// Adds a finalized phrase. Any volatile text it covers is removed, so the screen never
    /// shows the same words twice.
    @discardableResult
    public mutating func appendFinal(_ text: String, at date: Date = .now) -> CaptionLine? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if volatileOriginal.hasPrefix(trimmed), !trimmed.isEmpty {
            volatileOriginal = String(volatileOriginal.dropFirst(trimmed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            volatileOriginal = ""
        }
        volatileTranslation = nil
        guard !trimmed.isEmpty else { return nil }
        let line = CaptionLine(id: nextID, original: trimmed, finalizedAt: date)
        nextID += 1
        lines.append(line)
        if lines.count > maximumLines { lines.removeFirst(lines.count - maximumLines) }
        return line
    }

    public mutating func setTranslation(_ translation: String, forLine id: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].translation = translation
        lines[index].translationFailed = false
    }

    public mutating func markTranslationFailed(forLine id: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].translationFailed = true
    }

    /// Lines finalized within `window` seconds before `now`, newest last, at most `limit`.
    public func recentLines(limit: Int, within window: TimeInterval, now: Date = .now) -> [CaptionLine] {
        Array(lines.filter { now.timeIntervalSince($0.finalizedAt) <= window }.suffix(limit))
    }

    /// Original text of the lines just before `id`, oldest first, for translation context.
    public func context(before id: Int, count: Int) -> [String] {
        Array(lines.filter { $0.id < id }.suffix(count).map(\.original))
    }

    /// Plain-text transcript for copying.
    public var transcript: String {
        lines.map { line in
            if let translation = line.translation { "\(line.original)\n\(translation)" } else { line.original }
        }
        .joined(separator: "\n\n")
    }

    public mutating func reset() {
        lines.removeAll()
        volatileOriginal = ""
        volatileTranslation = nil
    }
}
