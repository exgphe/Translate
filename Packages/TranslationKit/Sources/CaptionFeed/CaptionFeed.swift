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
    public struct Line: Codable, Equatable, Sendable {
        public var id: Int
        public var original: String
        public var translation: String?
        public var finalizedAt: Date

        public init(id: Int, original: String, translation: String?, finalizedAt: Date) {
            self.id = id
            self.original = original
            self.translation = translation
            self.finalizedAt = finalizedAt
        }
    }

    /// One caption as displayed: the translation, with the original under it when wanted.
    public struct DisplayLine: Equatable, Sendable {
        public var primary: String
        public var secondary: String?
        public var isProvisional: Bool
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
    /// BCP-47 code of the caption text, used as the subtitle track's language.
    public var language: String

    public init(
        sessionID: UUID,
        isActive: Bool,
        updatedAt: Date,
        lines: [Line],
        volatileOriginal: String,
        volatileTranslation: String?,
        showsOriginal: Bool,
        language: String
    ) {
        self.sessionID = sessionID
        self.isActive = isActive
        self.updatedAt = updatedAt
        self.lines = lines
        self.volatileOriginal = volatileOriginal
        self.volatileTranslation = volatileTranslation
        self.showsOriginal = showsOriginal
        self.language = language
    }

    public func isLive(now: Date, timeout: TimeInterval = 15) -> Bool {
        isActive && now.timeIntervalSince(updatedAt) < timeout
    }

    /// What to show at `now`, with the same rules as the app's own caption display: the phrase
    /// in progress plus the last finished line, or the last two finished lines; finished lines
    /// disappear `lingering` seconds after they end.
    public func displayLines(now: Date, lingering: TimeInterval = 7) -> [DisplayLine] {
        let recent = lines.filter { now.timeIntervalSince($0.finalizedAt) <= lingering }
        let volatile = volatileOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = (volatile.isEmpty ? recent.suffix(2) : recent.suffix(1)).map {
            display(original: $0.original, translation: $0.translation, provisional: false)
        }
        if !volatile.isEmpty {
            result.append(display(original: volatile, translation: volatileTranslation, provisional: true))
        }
        return result
    }

    /// The display lines as plain cue text (WebVTT cue text uses line breaks for lines).
    public func cueText(now: Date) -> String {
        displayLines(now: now)
            .map { line in [line.primary, line.secondary].compactMap { $0 }.joined(separator: "\n") }
            .joined(separator: "\n")
    }

    private func display(original: String, translation: String?, provisional: Bool) -> DisplayLine {
        guard let translation, !translation.isEmpty else {
            return DisplayLine(primary: original, secondary: nil, isProvisional: provisional)
        }
        return DisplayLine(primary: translation, secondary: showsOriginal ? original : nil, isProvisional: provisional)
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
        guard let snapshot, snapshot.isLive(now: now) else { return ["active": false] }
        return [
            "active": true,
            "session": snapshot.sessionID.uuidString,
            "language": snapshot.language,
            "text": snapshot.cueText(now: now),
        ]
    }
}
