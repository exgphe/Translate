import Foundation

/// One finalized caption: what was said, and its translation once it arrives.
public struct CaptionLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public var original: String
    public var translation: String?
    public var translationFailed = false
    public let finalizedAt: Date
    public var translatedAt: Date?
    /// A two-row roll-up schedule gives completed translations time to be read.
    public var displayAfter: Date?
    public var displayUntil: Date?

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
    private var displaySlots: [Date] = []

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

    public mutating func setTranslation(_ translation: String, forLine id: Int, at date: Date = .now) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            lines[index].translationFailed = true
            return
        }
        lines[index].translation = text
        lines[index].translationFailed = false
        // Do not replay a completed line if its result is delivered twice.
        guard lines[index].translatedAt == nil else { return }
        let start = max(date, displaySlots.count < 2 ? date : displaySlots.removeFirst())
        let end = start.addingTimeInterval(Self.readingDuration(for: text))
        displaySlots.append(end)
        displaySlots.sort()
        lines[index].translatedAt = date
        lines[index].displayAfter = start
        lines[index].displayUntil = end
    }

    /// Short phrases need at least three seconds; longer sentences get up to eight.
    /// Count words for spaced scripts and characters for scripts such as Chinese/Japanese.
    private static func readingDuration(for text: String) -> TimeInterval {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let estimate = words > 1 ? Double(words) / 3 : Double(text.count) / 6
        return min(8, max(3, estimate))
    }

    /// The retained history is also the bounded FIFO for translation. No task is created
    /// for each recognized sentence, and a new sentence never discards an older job.
    public var nextUntranslatedLine: CaptionLine? {
        lines.first { $0.translation == nil && !$0.translationFailed }
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
        displaySlots.removeAll()
    }
}
