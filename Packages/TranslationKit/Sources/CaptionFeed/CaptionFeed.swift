import Foundation

/// Live captions shared from the app to its Safari web extension.
///
/// The app writes the current captions to a small JSON file in the App Group container; the
/// extension's native handler reads it whenever the content script polls, and the script
/// shows the text as a subtitle track on the page's `<video>`. Polling through native
/// messaging is the documented channel between a web extension and its app.
public enum CaptionFeed {
    /// App Group shared by the app and the extension. The identifier differs per platform
    /// (iOS and visionOS need "group.", macOS uses the team prefix), so both targets publish
    /// it in their Info.plist from the same build setting their entitlements use.
    public static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "CaptionFeedAppGroup") as? String ?? "group.wang.xiaolin.Translate"
    }
    public static let fileName = "live-captions.json"
}

public struct CaptionFeedSnapshot: Codable, Equatable, Sendable {
    /// Progress only; no audio or caption text is included in diagnostic replies.
    public struct Diagnostics: Codable, Equatable, Sendable {
        public var lastAudioAt: Date?
        public var audioBufferCount: Int
        public var lastTranscriptAt: Date?
        public var transcriptEventCount: Int

        public init(lastAudioAt: Date?, audioBufferCount: Int, lastTranscriptAt: Date?, transcriptEventCount: Int) {
            self.lastAudioAt = lastAudioAt
            self.audioBufferCount = audioBufferCount
            self.lastTranscriptAt = lastTranscriptAt
            self.transcriptEventCount = transcriptEventCount
        }
    }
    public struct Line: Codable, Equatable, Sendable {
        public var id: Int
        public var original: String
        public var translation: String?
        public var finalizedAt: Date
        public var translatedAt: Date?
        public var displayAfter: Date?
        public var displayUntil: Date?

        public init(id: Int, original: String, translation: String?, finalizedAt: Date, translatedAt: Date? = nil, displayAfter: Date? = nil, displayUntil: Date? = nil) {
            self.id = id
            self.original = original
            self.translation = translation
            self.finalizedAt = finalizedAt
            self.translatedAt = translatedAt
            self.displayAfter = displayAfter
            self.displayUntil = displayUntil
        }
    }

    /// One caption as displayed: the translation, with the original under it when wanted.
    public struct DisplayLine: Identifiable, Equatable, Sendable {
        public var id: String
        public var primary: String
        public var secondary: String?
        public var isProvisional: Bool

        public init(id: String, primary: String, secondary: String?, isProvisional: Bool) {
            self.id = id
            self.primary = primary
            self.secondary = secondary
            self.isProvisional = isProvisional
        }
    }

    public var sessionID: UUID
    public var isActive: Bool
    /// Refreshed at least every few seconds while captions run, so a reader can tell a live
    /// feed from one left behind by an app that was stopped or killed.
    public var updatedAt: Date
    public var lines: [Line]
    public var volatileOriginal: String
    public var volatileTranslation: String?
    public var showsOriginal: Bool
    /// Optional so an older on-disk feed still decodes. Old feeds default to translating.
    public var translationEnabled: Bool?
    /// BCP-47 code of the caption text, used as the subtitle track's language.
    public var language: String
    public var diagnostics: Diagnostics?

    public init(
        sessionID: UUID,
        isActive: Bool,
        updatedAt: Date,
        lines: [Line],
        volatileOriginal: String,
        volatileTranslation: String?,
        showsOriginal: Bool,
        language: String,
        diagnostics: Diagnostics? = nil,
        translationEnabled: Bool? = true
    ) {
        self.sessionID = sessionID
        self.isActive = isActive
        self.updatedAt = updatedAt
        self.lines = lines
        self.volatileOriginal = volatileOriginal
        self.volatileTranslation = volatileTranslation
        self.showsOriginal = showsOriginal
        self.language = language
        self.diagnostics = diagnostics
        self.translationEnabled = translationEnabled
    }

    public func isLive(now: Date, timeout: TimeInterval = 15) -> Bool {
        isActive && now.timeIntervalSince(updatedAt) < timeout
    }

    /// Completed translations use their reading slots, measured from completion rather than
    /// recognition. Untranslated speech can fill an empty row only when originals are wanted.
    public func displayLines(now: Date, lingering: TimeInterval = 7) -> [DisplayLine] {
        let translated = lines.filter { line in
            guard let text = line.translation, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let start = line.displayAfter ?? line.translatedAt ?? line.finalizedAt
            let end = line.displayUntil ?? start.addingTimeInterval(lingering)
            return start <= now && now < end
        }
        // Scheduled final translations own both rows until their reading time has elapsed.
        // A volatile phrase must never evict one, even if it already has a translation.
        var result = translated.suffix(2).compactMap { displayLine(for: $0) }
        if result.count < 2, let volatile = provisionalLine {
            result.append(volatile)
        }
        if result.count < 2 {
            let originals = lines.filter { line in
                line.translation == nil && now.timeIntervalSince(line.finalizedAt) <= lingering
            }.compactMap { displayLine(for: $0) }
            result.insert(contentsOf: originals.suffix(2 - result.count), at: 0)
        }
        return result
    }

    /// Retained transcript for a scrollable window. In translation mode, append finished
    /// results as they arrive: a burst of untranslated speech cannot push them out of view.
    public func historyLines() -> [DisplayLine] {
        var result = lines.filter { translationEnabled == false || $0.translation != nil }.compactMap { displayLine(for: $0) }
        if translationEnabled == false || volatileTranslation != nil, let provisionalLine { result.append(provisionalLine) }
        return result
    }

    public func displayLine(for line: Line) -> DisplayLine? {
        Self.displayLine(for: line, showsOriginal: showsOriginal, translationEnabled: translationEnabled != false)
    }

    public static func displayLine(for line: Line, showsOriginal: Bool, translationEnabled: Bool) -> DisplayLine? {
        display(id: "line-\(line.id)", original: line.original, translation: line.translation, provisional: false,
                showsOriginal: showsOriginal, translationEnabled: translationEnabled)
    }

    private var provisionalLine: DisplayLine? {
        Self.display(id: "volatile", original: volatileOriginal, translation: volatileTranslation, provisional: true,
                     showsOriginal: showsOriginal, translationEnabled: translationEnabled != false)
    }

    /// The display lines as plain cue text (WebVTT cue text uses line breaks for lines).
    public func cueText(now: Date) -> String {
        displayLines(now: now)
            .map { line in [line.primary, line.secondary].compactMap { $0 }.joined(separator: "\n") }
            .joined(separator: "\n")
    }

    private static func display(id: String, original: String, translation: String?, provisional: Bool, showsOriginal: Bool, translationEnabled: Bool) -> DisplayLine? {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        guard let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard showsOriginal || !translationEnabled else { return nil }
            return DisplayLine(id: id, primary: original, secondary: nil, isProvisional: provisional)
        }
        return DisplayLine(id: id, primary: translation, secondary: showsOriginal ? original : nil, isProvisional: provisional)
    }
}

/// Reads and writes the shared captions file.
public struct CaptionFeedStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The store in the shared App Group container, or nil when the entitlement is missing.
    public static func shared() -> CaptionFeedStore? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CaptionFeed.appGroupIdentifier) else {
            return nil
        }
        return CaptionFeedStore(url: container.appending(path: CaptionFeed.fileName))
    }

    public func write(_ snapshot: CaptionFeedSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func read() -> CaptionFeedSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CaptionFeedSnapshot.self, from: data)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The reply the extension's native handler sends to the content script. Property-list types
/// only, as native messaging requires.
public enum CaptionFeedReply {
    public static func make(from snapshot: CaptionFeedSnapshot?, now: Date = .now) -> [String: Any] {
        guard let snapshot else { return ["active": false, "status": "missing"] }
        let active = snapshot.isLive(now: now)
        var diagnostics: [String: Any] = ["feedAge": max(0, now.timeIntervalSince(snapshot.updatedAt))]
        if let progress = snapshot.diagnostics {
            diagnostics["audioBufferCount"] = progress.audioBufferCount
            diagnostics["transcriptEventCount"] = progress.transcriptEventCount
            if let time = progress.lastAudioAt { diagnostics["audioAge"] = max(0, now.timeIntervalSince(time)) }
            if let time = progress.lastTranscriptAt { diagnostics["transcriptAge"] = max(0, now.timeIntervalSince(time)) }
        }
        // Return progress even for stale feeds: the extension can distinguish an app/ASR
        // stall from a stopped session or a native-messaging failure.
        return [
            "active": active,
            "status": active ? "active" : (snapshot.isActive ? "stale" : "stopped"),
            "session": snapshot.sessionID.uuidString,
            "language": snapshot.language,
            "text": active ? snapshot.cueText(now: now) : "",
            "expiresAt": snapshot.updatedAt.addingTimeInterval(15).timeIntervalSince1970,
            "diagnostics": diagnostics,
        ]
    }
}
