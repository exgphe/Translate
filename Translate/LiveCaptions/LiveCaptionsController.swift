#if os(macOS) || os(visionOS) || os(iOS)
import CaptionFeed
import Foundation
import LiveCaptions
import Observation
import TranslationCore
import TranslationProviders
#if canImport(Translation) && !os(visionOS)
import Translation
#endif

/// Runs live captions: the person picks a window or app, its audio is recognized on device,
/// and each finished phrase is translated. Owns no UI; views and the overlay observe it.
@Observable
final class LiveCaptionsController {
    enum Phase: Equatable {
        case idle
        case choosingSource
        case preparing(String)
        case running
        case failed(String)

        var isActive: Bool {
            switch self {
            case .choosingSource, .preparing, .running: true
            case .idle, .failed: false
            }
        }
    }

    /// Who translates the captions. Chosen here, independently of the main window's engine.
    enum TranslatorChoice: Hashable, Identifiable {
        /// Apple's Translation framework (macOS): on device, the fastest option.
        case appleTranslation
        /// One of the app's engines: Apple Intelligence, Anthropic, an OpenAI-compatible service.
        case engine(String)
        /// Show the recognized speech only.
        case off

        var id: String { storageValue }

        var storageValue: String {
            switch self {
            case .appleTranslation: "appleTranslation"
            case .engine(let id): "engine:\(id)"
            case .off: "off"
            }
        }

        init?(storageValue: String) {
            switch storageValue {
            case "appleTranslation": self = .appleTranslation
            case "off": self = .off
            default:
                guard storageValue.hasPrefix("engine:") else { return nil }
                self = .engine(String(storageValue.dropFirst("engine:".count)))
            }
        }
    }

    enum AppleTranslationState: Equatable {
        case unknown
        /// Low-latency models installed: translates while people are still speaking.
        case readyLowLatency
        /// Only standard models installed: translates finished sentences, a bit slower.
        case readyStandard
        case needsDownload
        case unsupported
        case unavailable
    }

    /// One caption on screen.
    struct DisplayItem: Identifiable, Equatable {
        let id: String
        let primary: String
        let secondary: String?
        let isProvisional: Bool
    }

    private enum Key {
        static let spokenLocale = "captions.spokenLocale"
        static let target = "captions.targetLanguage"
        static let translator = "captions.translator"
        static let legacyMode = "captions.translationMode"
        static let showsOriginal = "captions.showsOriginal"
        static let textSize = "captions.textSize"
    }

    let settings: AppSettings
    let registry: EngineRegistry
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var phase: Phase = .idle
    private(set) var timeline = CaptionTimeline()
    private(set) var supportedLocales: [Locale] = []
    private(set) var appleTranslationState: AppleTranslationState = .unknown
    private(set) var activeTranslatorName: String?
    private(set) var lastTranslationError: String?

    var spokenLocaleIdentifier: String {
        didSet { defaults.set(spokenLocaleIdentifier, forKey: Key.spokenLocale) }
    }
    var targetLanguage: LanguageCode {
        didSet { defaults.set(targetLanguage.identifier, forKey: Key.target) }
    }
    var translator: TranslatorChoice {
        didSet { defaults.set(translator.storageValue, forKey: Key.translator) }
    }
    var showsOriginal: Bool {
        didSet { defaults.set(showsOriginal, forKey: Key.showsOriginal) }
    }
    var textSize: Double {
        didSet { defaults.set(textSize, forKey: Key.textSize) }
    }
    /// macOS: lets the caption panel take the mouse so it can be dragged into place.
    var isAdjustingPosition = false {
        didSet {
            #if os(macOS)
            overlay.setAdjusting(isAdjustingPosition, controller: self)
            #endif
        }
    }

    @ObservationIgnored private let picker = CaptureContentPicker()
    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    /// Captions shared with the Safari extension, which shows them on the page's video. Nil when
    /// the App Group entitlement is missing (for example in an unsigned build).
    @ObservationIgnored private let feedStore = CaptionFeedStore.shared()
    @ObservationIgnored private var feedSessionID = UUID()
    @ObservationIgnored private var feedWritePending = false
    @ObservationIgnored private var feedHeartbeat: Task<Void, Never>?
    @ObservationIgnored private var translationChain: Task<Void, Never>?
    @ObservationIgnored private var volatileTranslation: Task<Void, Never>?
    @ObservationIgnored private var lastVolatileSource = ""
    @ObservationIgnored private var newestLineID = -1
    #if os(macOS)
    @ObservationIgnored private let overlay = CaptionOverlayPanelController()
    #endif

    init(settings: AppSettings, registry: EngineRegistry, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.registry = registry
        self.defaults = defaults
        spokenLocaleIdentifier = defaults.string(forKey: Key.spokenLocale) ?? "en_US"
        targetLanguage = defaults.string(forKey: Key.target).map(LanguageCode.init) ?? settings.targetLanguage
        translator = Self.storedTranslator(defaults: defaults, settings: settings)
        showsOriginal = defaults.object(forKey: Key.showsOriginal) as? Bool ?? true
        textSize = defaults.object(forKey: Key.textSize) as? Double ?? 28
    }

    /// Every option, each engine listed on its own. The Translation framework is unavailable
    /// on visionOS.
    var availableTranslators: [TranslatorChoice] {
        var choices: [TranslatorChoice] = []
        #if !os(visionOS)
        choices.append(.appleTranslation)
        #endif
        choices += registry.engines.map { .engine($0.id) }
        choices.append(.off)
        return choices
    }

    private static func storedTranslator(defaults: UserDefaults, settings: AppSettings) -> TranslatorChoice {
        if let stored = defaults.string(forKey: Key.translator).flatMap(TranslatorChoice.init(storageValue:)) {
            #if os(visionOS)
            if stored == .appleTranslation { return .engine(AppleSystemModelProvider.providerID) }
            #endif
            return stored
        }
        switch defaults.string(forKey: Key.legacyMode) {
        case "off": return .off
        case "engine": return .engine(settings.selectedEngineID.isEmpty ? AppleSystemModelProvider.providerID : settings.selectedEngineID)
        default:
            #if os(visionOS)
            return .engine(AppleSystemModelProvider.providerID)
            #else
            return .appleTranslation
            #endif
        }
    }

    static var isCaptureAvailable: Bool { CaptureContentPicker.isAvailable }

    /// The spoken language as the app's language code (zh_CN → zh-Hans).
    var spokenLanguage: LanguageCode {
        let language = Locale(identifier: spokenLocaleIdentifier).language
        guard let code = language.languageCode?.identifier else { return .english }
        if code == "zh" {
            return language.maximalIdentifier.contains("Hant") ? .traditionalChinese : .simplifiedChinese
        }
        return LanguageCode(code)
    }

    /// Translating into the language being spoken is pointless; show the original instead.
    var translationNeeded: Bool {
        guard translator != .off else { return false }
        // Simplified ↔ Traditional Chinese is still a useful conversion.
        if spokenLanguage.identifier.hasPrefix("zh"), targetLanguage.identifier.hasPrefix("zh") {
            return spokenLanguage != targetLanguage
        }
        return spokenLanguage.locale.language.languageCode != targetLanguage.locale.language.languageCode
    }

    // MARK: - Setup data

    func loadLocales() async {
        guard supportedLocales.isEmpty else { return }
        supportedLocales = await LiveTranscriber.supportedLocales()
    }

    func refreshAppleTranslationState() async {
        #if canImport(Translation) && !os(visionOS)
        switch await AppleCaptionTranslator.readiness(source: appleSourceLanguage, target: appleTargetLanguage) {
        case .lowLatency: appleTranslationState = .readyLowLatency
        case .standard: appleTranslationState = .readyStandard
        case .needsDownload: appleTranslationState = .needsDownload
        case .unsupported: appleTranslationState = .unsupported
        }
        #else
        appleTranslationState = .unavailable
        #endif
    }

    var appleSourceLanguage: Locale.Language { Locale.Language(identifier: spokenLanguage.identifier) }
    var appleTargetLanguage: Locale.Language { Locale.Language(identifier: targetLanguage.identifier) }

    // MARK: - Run

    func start() async {
        guard !phase.isActive else { return }
        guard Self.isCaptureAvailable else {
            phase = .failed(LiveCaptionsError.captureUnavailable.localizedDescription)
            return
        }
        lastTranslationError = nil

        let translator: (any CaptionTranslating)?
        do {
            translator = try await makeTranslator()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .choosingSource
        let source: CaptureSource
        do {
            source = try await picker.pick()
        } catch LiveCaptionsError.pickerCancelled {
            phase = .idle
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .preparing("Preparing speech recognition…")
        do {
            let transcriber = try await LiveTranscriber.prepare(locale: Locale(identifier: spokenLocaleIdentifier)) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .preparing = self.phase else { return }
                    self.phase = .preparing("Downloading the speech model… \(Int(fraction * 100))%")
                }
            }
            let capture = SystemAudioCapture()
            let audio = try await capture.start(source: source) { [weak self] error in
                Task { @MainActor in self?.captureEnded(error) }
            }
            self.capture = capture
            timeline.reset()
            newestLineID = -1
            lastVolatileSource = ""
            activeTranslatorName = translator?.displayName
            phase = .running
            #if os(macOS)
            overlay.show(controller: self)
            #endif
            feedSessionID = UUID()
            writeFeed()
            // Readers treat a feed that stops updating as gone, so refresh it during silence too.
            feedHeartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    writeFeed()
                }
            }
            let events = transcriber.transcribe(audio)
            pipeline = Task { await self.consume(events, translator: translator) }
        } catch {
            phase = .failed(error.localizedDescription)
            await teardown()
        }
    }

    func stop() async {
        await teardown()
        if phase.isActive { phase = .idle }
    }

    private func teardown() async {
        feedHeartbeat?.cancel()
        feedHeartbeat = nil
        writeFeed(active: false)
        pipeline?.cancel()
        translationChain?.cancel()
        volatileTranslation?.cancel()
        pipeline = nil
        translationChain = nil
        volatileTranslation = nil
        let capture = self.capture
        self.capture = nil
        await capture?.stop()
        picker.deactivate()
        isAdjustingPosition = false
        #if os(macOS)
        overlay.hide()
        #endif
    }

    private func captureEnded(_ error: LiveCaptionsError?) {
        Task {
            await teardown()
            phase = error.map { .failed($0.localizedDescription) } ?? .idle
        }
    }

    private func consume(_ events: AsyncThrowingStream<TranscriptEvent, any Error>, translator: (any CaptionTranslating)?) async {
        do {
            for try await event in events {
                switch event {
                case .volatile(let text):
                    timeline.updateVolatile(text)
                    if let translator, translator.translatesVolatileText { translateVolatile(using: translator) }
                case .final(let text):
                    guard let line = timeline.appendFinal(text) else { continue }
                    newestLineID = line.id
                    if let translator { enqueueTranslation(of: line, using: translator) }
                }
                publishFeed()
            }
            if phase == .running { await stop() }
        } catch is CancellationError {
            // Stopped on purpose.
        } catch {
            phase = .failed(error.localizedDescription)
            await teardown()
        }
    }

    /// Finished phrases are translated in order. A slow engine that falls behind skips lines
    /// that have already scrolled away, so the captions on screen stay current.
    private func enqueueTranslation(of line: CaptionLine, using translator: any CaptionTranslating) {
        let previous = translationChain
        let context = timeline.context(before: line.id, count: 3)
        translationChain = Task {
            await previous?.value
            guard !Task.isCancelled, line.id >= newestLineID - 2 else { return }
            do {
                let translation = try await translator.translate(line.original, previousLines: context)
                timeline.setTranslation(translation, forLine: line.id)
                publishFeed()
            } catch is CancellationError {
            } catch {
                timeline.markTranslationFailed(forLine: line.id)
                lastTranslationError = Self.describe(error)
            }
        }
    }

    /// Keeps at most one provisional translation of the phrase in progress in flight.
    private func translateVolatile(using translator: any CaptionTranslating) {
        guard volatileTranslation == nil else { return }
        volatileTranslation = Task {
            defer { volatileTranslation = nil }
            while !Task.isCancelled {
                let source = timeline.volatileOriginal
                guard !source.isEmpty, source != lastVolatileSource else { return }
                lastVolatileSource = source
                guard let translation = try? await translator.translate(source, previousLines: []) else { return }
                timeline.setVolatileTranslation(translation, source: source)
                publishFeed()
            }
        }
    }

    /// Errors with the cause spelled out: the Translation framework's own descriptions are all
    /// "Unable to Translate", and engine errors carry a recovery hint.
    static func describe(_ error: any Error) -> String {
        if let error = error as? TranslationCore.TranslationError {
            return [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        if let error = error as? any LocalizedError {
            return [error.errorDescription, error.failureReason].compactMap { $0 }.joined(separator: " ")
        }
        return error.localizedDescription
    }

    private func makeTranslator() async throws -> (any CaptionTranslating)? {
        guard translationNeeded else { return nil }
        switch translator {
        case .off:
            return nil
        case .engine(let id):
            guard let provider = registry.makeProvider(id: id) else {
                throw CaptionSetupError.message("That translation engine is no longer available. Choose another one.")
            }
            let availability = await provider.availability()
            guard availability.isAvailable else {
                throw CaptionSetupError.message(availability.message ?? "\(provider.displayName) is not available.")
            }
            return ProviderCaptionTranslator(
                provider: provider,
                sourceLanguage: spokenLanguage,
                targetLanguage: targetLanguage,
                networkPolicy: settings.networkPolicy
            )
        case .appleTranslation:
            #if canImport(Translation) && !os(visionOS)
            await refreshAppleTranslationState()
            switch appleTranslationState {
            case .readyLowLatency, .readyStandard:
                return AppleCaptionTranslator(
                    source: appleSourceLanguage,
                    target: appleTargetLanguage,
                    lowLatency: appleTranslationState == .readyLowLatency
                )
            case .needsDownload:
                throw CaptionSetupError.message("Download the \(spokenLanguage.displayName()) → \(targetLanguage.displayName()) languages for Apple Translation first.")
            default:
                throw CaptionSetupError.message("Apple Translation does not support \(spokenLanguage.displayName()) → \(targetLanguage.displayName()). Choose another translation engine.")
            }
            #else
            return nil
            #endif
        }
    }

    // MARK: - Safari extension feed

    /// Shares the captions with the Safari extension, coalescing bursts of updates.
    private func publishFeed() {
        guard feedStore != nil, !feedWritePending else { return }
        feedWritePending = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            writeFeed()
        }
    }

    private func writeFeed(active: Bool = true) {
        feedWritePending = false
        guard let feedStore else { return }
        let snapshot = CaptionFeedSnapshot(
            sessionID: feedSessionID,
            isActive: active && phase == .running,
            updatedAt: .now,
            lines: timeline.lines.suffix(8).map {
                .init(id: $0.id, original: $0.original, translation: $0.translation, finalizedAt: $0.finalizedAt)
            },
            volatileOriginal: timeline.volatileOriginal,
            volatileTranslation: timeline.volatileTranslation,
            showsOriginal: showsOriginal,
            language: activeTranslatorName == nil ? spokenLanguage.identifier : targetLanguage.identifier
        )
        try? feedStore.write(snapshot)
    }

    // MARK: - Display

    /// What the caption overlay shows now: the phrase in progress and the last finished line,
    /// or the last two finished lines. Lines disappear a few seconds after they end.
    func displayItems(now: Date) -> [DisplayItem] {
        let recent = timeline.recentLines(limit: 2, within: 7, now: now)
        var items: [DisplayItem] = []
        let finals = timeline.volatileOriginal.isEmpty ? recent : Array(recent.suffix(1))
        for line in finals {
            items.append(item(id: "line-\(line.id)", original: line.original, translation: line.translation, provisional: false))
        }
        if !timeline.volatileOriginal.isEmpty {
            items.append(item(id: "volatile", original: timeline.volatileOriginal, translation: timeline.volatileTranslation, provisional: true))
        }
        return items
    }

    private func item(id: String, original: String, translation: String?, provisional: Bool) -> DisplayItem {
        guard let translation, !translation.isEmpty else {
            return DisplayItem(id: id, primary: original, secondary: nil, isProvisional: provisional)
        }
        return DisplayItem(id: id, primary: translation, secondary: showsOriginal ? original : nil, isProvisional: provisional)
    }

    var statusText: String {
        switch phase {
        case .idle: "Not running."
        case .choosingSource: "Choose a window or app in the system picker."
        case .preparing(let message): message
        case .running: activeTranslatorName.map { "Captioning. Translating with \($0)." } ?? "Captioning without translation."
        case .failed(let message): message
        }
    }
}

enum CaptionSetupError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
#endif
