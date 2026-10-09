import Foundation
import Testing
@testable import CaptionFeed

struct CaptionFeedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func popupRoutesKeepSettingsSeparateFromStartingCapture() throws {
        #expect(CaptionAppRoute(url: try #require(URL(string: "translate-live-captions://captions/start"))) == .start)
        #expect(CaptionAppRoute(url: try #require(URL(string: "translate-live-captions://captions/settings"))) == .settings)
        for value in ["https://captions/start", "translate-live-captions://other/start",
                      "translate-live-captions://captions/stop", "translate-live-captions://captions/start?target=en",
                      "translate-live-captions://captions/settings#start", "translate-live-captions://user@captions/start"] {
            #expect(CaptionAppRoute(url: try #require(URL(string: value))) == nil)
        }
    }

    @Test func extensionConfigurationPersistsWithoutAnActiveCaptionFeed() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "caption-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptionExtensionConfigurationStore(url: url)
        #expect(store.read() == nil)
        var configuration = CaptionExtensionConfiguration(spokenLanguage: "en", targetLanguage: "zh-Hans", translationEnabled: true)
        try store.write(configuration)
        #expect(store.read() == configuration)
        configuration.translationEnabled = false
        try store.write(configuration)
        #expect(store.read()?.translationEnabled == false)
        #expect(Set(configuration.reply.keys) == ["spokenLanguage", "targetLanguage", "translationEnabled"])
        #expect(PropertyListSerialization.propertyList(configuration.reply, isValidFor: .binary))
        try Data("invalid".utf8).write(to: url)
        #expect(store.read() == nil)
    }

    private func snapshot(lines: [CaptionFeedSnapshot.Line] = [], volatile: String = "", volatileTranslation: String? = nil, showsOriginal: Bool = true, updatedAgo: TimeInterval = 1, active: Bool = true) -> CaptionFeedSnapshot {
        CaptionFeedSnapshot(sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, isActive: active, updatedAt: now.addingTimeInterval(-updatedAgo), lines: lines, volatileOriginal: volatile, volatileTranslation: volatileTranslation, showsOriginal: showsOriginal, language: "zh-Hans")
    }

    private func line(_ id: Int, _ original: String, _ translation: String?, ago: TimeInterval) -> CaptionFeedSnapshot.Line {
        .init(id: id, original: original, translation: translation, finalizedAt: now.addingTimeInterval(-ago))
    }

    @Test func roundTripsThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptionFeedStore(url: url)
        let original = snapshot(lines: [line(0, "Hello.", "你好。", ago: 2)], volatile: "How are", volatileTranslation: "怎么样")
        try store.write(original)
        #expect(store.read() == original)
        store.remove()
        #expect(store.read() == nil)
    }

    @Test func showsTheLastLineAndThePhraseInProgress() {
        let feed = snapshot(lines: [line(0, "One.", "一。", ago: 5), line(1, "Two.", "二。", ago: 3)], volatile: "Three", volatileTranslation: "三")
        #expect(feed.displayLines(now: now).map(\.primary) == ["二。", "三"])
        #expect(feed.cueText(now: now) == "二。\nTwo.\n三\nThree")
    }

    @Test func finishedLinesExpireAndOriginalCanBeHidden() {
        let feed = snapshot(lines: [line(0, "Old.", "旧。", ago: 30), line(1, "New.", "新。", ago: 2)], showsOriginal: false)
        #expect(feed.cueText(now: now) == "新。")
    }

    @Test func untranslatedLinesShowTheOriginal() {
        let feed = snapshot(lines: [line(0, "Pending.", nil, ago: 1)])
        #expect(feed.cueText(now: now) == "Pending.")
    }

    @Test func replyIsInactiveWhenStoppedOrStale() {
        #expect(CaptionFeedReply.make(from: nil, now: now)["active"] as? Bool == false)
        #expect(CaptionFeedReply.make(from: snapshot(active: false), now: now)["active"] as? Bool == false)
        #expect(CaptionFeedReply.make(from: snapshot(updatedAgo: 60), now: now)["active"] as? Bool == false)
        let live = CaptionFeedReply.make(from: snapshot(lines: [line(0, "Hi.", "嗨。", ago: 1)]), now: now)
        #expect(live["active"] as? Bool == true)
        #expect(live["text"] as? String == "嗨。\nHi.")
        #expect(live["language"] as? String == "zh-Hans")
        #expect(live["session"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(PropertyListSerialization.propertyList(live, isValidFor: .binary))
    }

    @Test func staleReplyRetainsProgressWithoutCaptionContent() throws {
        var feed = snapshot(lines: [line(0, "Private words.", "私人文字。", ago: 1)], updatedAgo: 60)
        feed.diagnostics = .init(lastAudioAt: now.addingTimeInterval(-2), audioBufferCount: 1234,
                                 lastTranscriptAt: now.addingTimeInterval(-45), transcriptEventCount: 42)
        let reply = CaptionFeedReply.make(from: feed, now: now)
        #expect(reply["active"] as? Bool == false)
        #expect(reply["status"] as? String == "stale")
        #expect(reply["text"] as? String == "")
        let progress = try #require(reply["diagnostics"] as? [String: Any])
        #expect(progress["feedAge"] as? Double == 60)
        #expect(progress["audioAge"] as? Double == 2)
        #expect(progress["transcriptAge"] as? Double == 45)
        #expect(progress["audioBufferCount"] as? Int == 1234)
        #expect(progress["transcriptEventCount"] as? Int == 42)
        #expect(PropertyListSerialization.propertyList(reply, isValidFor: .binary))
    }

    @Test func diagnosticsRoundTripAndOldFeedsStillDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var feed = snapshot()
        feed.diagnostics = .init(lastAudioAt: now, audioBufferCount: 1, lastTranscriptAt: nil, transcriptEventCount: 0)
        #expect(try decoder.decode(CaptionFeedSnapshot.self, from: encoder.encode(feed)) == feed)
        var old = try #require(JSONSerialization.jsonObject(with: encoder.encode(feed)) as? [String: Any])
        old.removeValue(forKey: "diagnostics")
        #expect(try decoder.decode(CaptionFeedSnapshot.self, from: JSONSerialization.data(withJSONObject: old)).diagnostics == nil)
    }
}
