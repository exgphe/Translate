import Foundation

/// User-initiated links from the Safari popup. Opening settings never starts capture.
public enum CaptionAppRoute: String, Sendable {
    case start
    case settings

    public static let scheme = "translate-live-captions"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "captions",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        switch url.path {
        case "/start": self = .start
        case "/settings": self = .settings
        default: return nil
        }
    }
}

/// Language preferences only; readable even when the caption session has stopped.
public struct CaptionExtensionConfiguration: Codable, Equatable, Sendable {
    public var spokenLanguage: String
    public var targetLanguage: String
    public var translationEnabled: Bool

    public init(spokenLanguage: String, targetLanguage: String, translationEnabled: Bool) {
        self.spokenLanguage = spokenLanguage
        self.targetLanguage = targetLanguage
        self.translationEnabled = translationEnabled
    }

    public var reply: [String: Any] {
        ["spokenLanguage": spokenLanguage, "targetLanguage": targetLanguage,
         "translationEnabled": translationEnabled]
    }
}

public struct CaptionExtensionConfigurationStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func shared() -> Self? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CaptionFeed.appGroupIdentifier) else { return nil }
        return Self(url: container.appending(path: "live-caption-settings.json"))
    }

    public func write(_ configuration: CaptionExtensionConfiguration) throws {
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
    }

    public func read() -> CaptionExtensionConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CaptionExtensionConfiguration.self, from: data)
    }
}
