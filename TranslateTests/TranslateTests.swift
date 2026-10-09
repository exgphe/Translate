//
//  TranslateTests.swift
//  TranslateTests
//

import CaptionFeed
import Foundation
import LiveCaptions
import Testing
import TranslationCore
#if canImport(Translation) && os(macOS)
import Translation
#endif
@testable import Translate

#if canImport(Translation) && os(macOS)
/// Runs inside the app process: the Translation framework does not answer command-line tools,
/// so live captions' Apple Translation path can only be checked from here.
struct AppleTranslationHostedTests {
    @Test(.timeLimit(.minutes(1)))
    func lowLatencyTranslationWorksInTheApp() async throws {
        let english = Locale.Language(identifier: "en")
        let chinese = Locale.Language(identifier: "zh-Hans")
        let status = await LanguageAvailability().status(from: english, to: chinese)
        print("APPLE TRANSLATION STATUS:", status)
        try #require(status == .installed, "English → Simplified Chinese is not downloaded on this Mac (\(status)).")

        let session = TranslationSession(installedSource: english, target: chinese, preferredStrategy: .lowLatency)
        for text in ["Please bring the signed forms on Thursday.", "Break a leg tonight!"] {
            let start = Date()
            let response = try await session.translate(text)
            print("APPLE TRANSLATION \(Int(Date().timeIntervalSince(start) * 1000)) ms:", response.targetText)
            #expect(!response.targetText.isEmpty)
        }
    }
}

/// Reproduces how live captions call Apple Translation: overlapping requests (the phrase in
/// progress and the finished line) and rapid growing prefixes.
struct AppleTranslationConcurrencyTests {
    static let english = Locale.Language(identifier: "en")
    static let chinese = Locale.Language(identifier: "zh-Hans")

    static func describe(_ error: any Error) -> String {
        guard let error = error as? Translation.TranslationError else { return "other: \(error)" }
        let known: [(String, Translation.TranslationError)] = [
            ("unsupportedSourceLanguage", .unsupportedSourceLanguage), ("unsupportedTargetLanguage", .unsupportedTargetLanguage),
            ("unsupportedLanguagePairing", .unsupportedLanguagePairing), ("unableToIdentifyLanguage", .unableToIdentifyLanguage),
            ("nothingToTranslate", .nothingToTranslate), ("alreadyCancelled", .alreadyCancelled),
            ("notInstalled", .notInstalled), ("internalError", .internalError),
        ]
        let name = known.first { $0.1 ~= error }?.0 ?? "unknown"
        return "\(name): \(error.errorDescription ?? "") / \(error.failureReason ?? "")"
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingRequestsOnOneSession() async throws {
        let session = TranslationSession(installedSource: Self.english, target: Self.chinese, preferredStrategy: .lowLatency)
        async let a: String = { do { return try await session.translate("The meeting has been moved").targetText } catch { return "ERROR " + Self.describe(error) } }()
        async let b: String = { do { return try await session.translate("Please bring the signed forms on Thursday.").targetText } catch { return "ERROR " + Self.describe(error) } }()
        let results = await [a, b]
        print("ONE SESSION, OVERLAPPING:", results)
        #expect(!results.contains { $0.hasPrefix("ERROR") })
    }

    @Test(.timeLimit(.minutes(1)))
    func rapidGrowingPrefixesOnOneSession() async throws {
        let session = TranslationSession(installedSource: Self.english, target: Self.chinese, preferredStrategy: .lowLatency)
        var outcomes: [String] = []
        for prefix in ["The", "The meeting", "The meeting has", "The meeting has been moved", "The meeting has been moved to Thursday"] {
            do { outcomes.append(try await session.translate(prefix).targetText) } catch { outcomes.append("ERROR " + Self.describe(error)) }
        }
        print("ONE SESSION, SEQUENTIAL PREFIXES:", outcomes)
        #expect(!outcomes.contains { $0.hasPrefix("ERROR") })
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingRequestsOnTwoSessions() async throws {
        let first = TranslationSession(installedSource: Self.english, target: Self.chinese, preferredStrategy: .lowLatency)
        let second = TranslationSession(installedSource: Self.english, target: Self.chinese, preferredStrategy: .lowLatency)
        async let a: String = { do { return try await first.translate("The meeting has been moved").targetText } catch { return "ERROR " + Self.describe(error) } }()
        async let b: String = { do { return try await second.translate("Please bring the signed forms on Thursday.").targetText } catch { return "ERROR " + Self.describe(error) } }()
        let results = await [a, b]
        print("TWO SESSIONS, OVERLAPPING:", results)
        #expect(!results.contains { $0.hasPrefix("ERROR") })
    }
}

/// Low-latency models are a separate download: a pair can be installed for the standard
/// strategy but not for low latency. Live captions must then fall back to the standard models,
/// and show the error's failure reason, because every error's description is "Unable to Translate".
struct AppleTranslationStrategyTests {
    @Test(.timeLimit(.minutes(2)))
    func standardModelsTranslateWhenLowLatencyIsMissing() async throws {
        let pairs = [("en", "ja"), ("en", "zh-Hant"), ("ja", "en"), ("en", "zh-Hans")]
        var checked = 0
        var timings: [String] = []
        for (source, target) in pairs {
            let s = Locale.Language(identifier: source), t = Locale.Language(identifier: target)
            let fast = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: s, to: t)
            let standard = await LanguageAvailability().status(from: s, to: t)
            guard fast != .installed, standard == .installed else { continue }
            checked += 1

            // The low-latency session fails with notInstalled, whose reason names the cause.
            do {
                _ = try await TranslationSession(installedSource: s, target: t, preferredStrategy: .lowLatency).translate("Thank you very much.")
                Issue.record("Expected notInstalled for \(source)->\(target) with low latency")
            } catch let error as Translation.TranslationError {
                #expect(error.errorDescription == "Unable to Translate")
                #expect(error.failureReason?.contains("downloaded") == true)
            }

            let session = TranslationSession(installedSource: s, target: t, preferredStrategy: .highFidelity)
            let start = Date()
            let text = try await session.translate(source == "ja" ? "ありがとうございます。" : "Thank you very much.").targetText
            timings.append("\(source)->\(target) \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            #expect(!text.isEmpty)
        }
        if checked == 0 {
            withKnownIssue("Every probed pair already has low-latency models on this Mac") { Issue.record("nothing to check") }
        }
        // Measured on 2026-10-08, first call per pair including model load:
        // en->ja 2704 ms, en->zh-Hant 531 ms, ja->en 1054 ms. Too slow for the phrase in
        // progress, fine for finished sentences.
        _ = timings
    }
}

/// The live captions controller, as configured by the panel, against this Mac's real models.
@MainActor
struct LiveCaptionsAppleTranslationTests {
    private func makeController() -> LiveCaptionsController {
        let defaults = UserDefaults(suiteName: "LiveCaptionsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        return LiveCaptionsController(settings: settings, registry: EngineRegistry(settings: settings), defaults: defaults)
    }

    @Test func everyEngineIsListedSeparately() {
        let controller = makeController()
        #expect(controller.availableTranslators.first == .appleTranslation)
        #expect(controller.availableTranslators.contains(.engine("apple.system")))
        #expect(controller.availableTranslators.contains(.engine("anthropic")))
        #expect(controller.availableTranslators.last == .off)
    }

    @Test(.timeLimit(.minutes(2)))
    func pairWithoutLowLatencyModelsUsesStandardModels() async throws {
        // Which pairs lack low-latency models changes as the system downloads them, so pick one now.
        let candidates = [("en_US", "ja"), ("en_US", "zh-Hant"), ("ja_JP", "en"), ("de_DE", "en"), ("ja_JP", "zh-Hans"), ("en_US", "de"), ("en_US", "ko"), ("fr_FR", "en")]
        let controller = makeController()
        var found = false
        for (spoken, target) in candidates {
            controller.spokenLocaleIdentifier = spoken
            controller.targetLanguage = LanguageCode(target)
            await controller.refreshAppleTranslationState()
            if controller.appleTranslationState == .readyStandard { found = true; break }
        }
        guard found else {
            withKnownIssue("Every candidate pair has low-latency models on this Mac now") { Issue.record("no standard-only pair") }
            return
        }

        let translator = AppleCaptionTranslator(source: controller.appleSourceLanguage, target: controller.appleTargetLanguage, lowLatency: false)
        let text = try await translator.translate("Thank you very much.", previousLines: [])
        #expect(!text.isEmpty)
        #expect(!translator.translatesVolatileText)

        // The behaviour behind "Unable to Translate": low latency on this pair fails, now with its reason.
        let lowLatencyTranslator = AppleCaptionTranslator(source: controller.appleSourceLanguage, target: controller.appleTargetLanguage, lowLatency: true)
        await #expect(throws: LiveCaptionsError.translationFailed("Languages must be downloaded on-device.")) {
            _ = try await lowLatencyTranslator.translate("Thank you very much.", previousLines: [])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pairWithLowLatencyModelsTranslatesTheVolatilePhrase() async throws {
        let controller = makeController()
        controller.spokenLocaleIdentifier = "en_US"
        controller.targetLanguage = .simplifiedChinese
        await controller.refreshAppleTranslationState()
        try #require(controller.appleTranslationState == .readyLowLatency)
        let translator = AppleCaptionTranslator(source: controller.appleSourceLanguage, target: controller.appleTargetLanguage, lowLatency: true)
        #expect(translator.translatesVolatileText)
        #expect(try await translator.translate("Break a leg tonight!", previousLines: []).isEmpty == false)
    }
}

/// The app side of the Safari extension bridge: the signed, sandboxed app can reach the App
/// Group container the extension reads from.
struct CaptionFeedAppGroupTests {
    @Test func appGroupContainerRoundTripsCaptions() throws {
        let store = try #require(CaptionFeedStore.shared(), "No App Group container; check the application-groups entitlement")
        #expect(CaptionFeed.appGroupIdentifier.hasSuffix("wang.xiaolin.Translate"))
        // Whole seconds: the file stores dates as seconds, so sub-microsecond parts don't survive.
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded())
        let snapshot = CaptionFeedSnapshot(
            sessionID: UUID(), isActive: true, updatedAt: now,
            lines: [.init(id: 0, original: "Hello.", translation: "你好。", finalizedAt: now)],
            volatileOriginal: "", volatileTranslation: nil, showsOriginal: true, language: "zh-Hans"
        )
        try store.write(snapshot)
        defer { store.remove() }
        #expect(store.read() == snapshot)
        #expect(CaptionFeedReply.make(from: store.read())["text"] as? String == "你好。\nHello.")
    }
}
#endif

