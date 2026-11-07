import Foundation
import Synchronization
import Testing
import TranslationCore
@testable import Translate

@MainActor
struct SystemTranslationSettingsTests {
    @Test func sharesOnlyTranslationConfigurationAndPreservesExistingPreferences() {
        let appName = "SystemTranslationApp-\(UUID())"
        let sharedName = "SystemTranslationShared-\(UUID())"
        let app = UserDefaults(suiteName: appName)!
        let shared = UserDefaults(suiteName: sharedName)!
        defer {
            app.removePersistentDomain(forName: appName)
            shared.removePersistentDomain(forName: sharedName)
        }
        app.set("anthropic", forKey: "engine.selected")
        app.set("ja", forKey: "language.target")
        app.set(true, forKey: "privacy.onDeviceOnly")
        app.set(true, forKey: "clipboard.autoPaste")
        app.set(false, forKey: "history.enabled")
        let settings = AppSettings(defaults: app, sharedTranslationDefaults: shared)
        let service = AppSettings(defaults: shared)
        #expect(service.selectedEngineID == "anthropic")
        #expect(service.targetLanguage == .japanese)
        #expect(service.networkPolicy == .onDeviceOnly)
        #expect(settings.autoPasteEnabled)
        #expect(!settings.historyEnabled)
        #expect(shared.object(forKey: "clipboard.autoPaste") == nil)
        #expect(shared.object(forKey: "history.enabled") == nil)
        settings.openAIBaseURL = "https://example.test/v1"
        settings.openAIModel = "test-model"
        settings.sourceLanguage = .explicit(.english)
        settings.targetLanguage = .korean
        settings.onDeviceOnly = false
        let updated = AppSettings(defaults: shared)
        #expect(updated.openAIBaseURL == settings.openAIBaseURL)
        #expect(updated.openAIModel == "test-model")
        #expect(updated.sourceLanguage == .explicit(.english))
        #expect(updated.targetLanguage == .korean)
        #expect(updated.networkPolicy == .allowCloud)
        #expect(shared.dictionaryRepresentation().keys.allSatisfy { !$0.contains("apiKey") })
    }
}

nonisolated private final class ControlledSelectionProvider: TranslationProvider, Sendable {
    let id = "selection.test"
    let displayName = "Selection test"
    let capabilities: ProviderCapabilities
    let stream: AsyncThrowingStream<TranslationEvent, any Error>
    let continuation: AsyncThrowingStream<TranslationEvent, any Error>.Continuation
    let requests = Mutex<[TranslationRequest]>([])

    init(location: ProcessingLocation = .onDevice) {
        capabilities = ProviderCapabilities(supportsStreaming: true, supportsImages: false, processingLocation: location)
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func availability() async -> ProviderAvailability { .available }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        requests.withLock { $0.append(request) }
        return stream
    }

    var requestCount: Int { requests.withLock { $0.count } }

    func complete(_ text: String) throws {
        let request = try #require(requests.withLock { $0.last })
        continuation.yield(.completed(TranslationResult(
            requestID: request.id, text: text, providerID: id,
            modelName: displayName, processingLocation: capabilities.processingLocation
        )))
        continuation.finish()
    }
}

@MainActor
struct SystemTranslationLifecycleTests {
    private func model(for provider: ControlledSelectionProvider) -> SelectedTextTranslation {
        let model = SelectedTextTranslation()
        model.input = "Please bring the signed forms on Thursday."
        model.engineID = provider.id
        return model
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "Translation task did not reach its expected state.")
    }

    @Test func onlyCompletedTranslationCanReplace() async throws {
        let provider = ControlledSelectionProvider()
        let model = model(for: provider)
        model.translate(using: provider)
        try await wait { provider.requestCount == 1 }
        provider.continuation.yield(.textDelta("请在"))
        try await wait { !model.text.isEmpty }
        #expect(model.completedText == nil)
        try provider.complete("请在周四带上签好的表格。")
        try await wait { !model.isTranslating }
        #expect(model.completedText == "请在周四带上签好的表格。")
    }

    @Test func automaticTranslationStartsOnceAndDoesNotRestartAfterStopping() async throws {
        let provider = ControlledSelectionProvider()
        let model = model(for: provider)
        model.translateAutomatically(using: provider)
        try await wait { provider.requestCount == 1 }
        model.translateAutomatically(using: provider)
        #expect(provider.requestCount == 1)
        model.cancel()
        model.translateAutomatically(using: provider)
        #expect(!model.isTranslating)
        #expect(provider.requestCount == 1)
        try provider.complete("Late result")
        #expect(model.completedText == nil)
    }

    @Test func changedLanguageAutomaticallyTranslatesAndRejectsOldResponse() async throws {
        let oldProvider = ControlledSelectionProvider()
        let model = model(for: oldProvider)
        model.translateAutomatically(using: oldProvider)
        try await wait { oldProvider.requestCount == 1 }
        model.targetLanguage = .japanese
        let newProvider = ControlledSelectionProvider()
        model.translateAutomatically(using: newProvider)
        try await wait { newProvider.requestCount == 1 }
        #expect(newProvider.requests.withLock { $0.last?.targetLanguage } == .japanese)
        try oldProvider.complete("Stale result")
        try newProvider.complete("木曜日に書類を持ってきてください。")
        try await wait { !model.isTranslating }
        #expect(model.text == "木曜日に書類を持ってきてください。")
        #expect(model.completedText == model.text)
        model.translateAutomatically(using: newProvider)
        #expect(!model.isTranslating)
        #expect(newProvider.requestCount == 1)
    }

    @Test func automaticTranslationSkipsEmptyInputAndPreservesCloudPolicy() async throws {
        let provider = ControlledSelectionProvider(location: .cloud)
        let model = model(for: provider)
        model.input = " \n "
        model.translateAutomatically(using: provider)
        #expect(!model.isTranslating)
        #expect(provider.requestCount == 0)
        model.input = "Translate this selection."
        model.networkPolicy = .onDeviceOnly
        model.translateAutomatically(using: provider)
        try await wait { !model.isTranslating }
        #expect(provider.requestCount == 0)
        #expect(model.error != nil)
        model.translateAutomatically(using: provider)
        #expect(!model.isTranslating)
    }

    @Test func changedSelectionRejectsLateCompletion() async throws {
        let oldProvider = ControlledSelectionProvider()
        let model = model(for: oldProvider)
        model.translate(using: oldProvider)
        try await wait { oldProvider.requestCount == 1 }
        model.input = "Another selection."
        try oldProvider.complete("Stale translation")
        let newProvider = ControlledSelectionProvider()
        model.translate(using: newProvider)
        try await wait { newProvider.requestCount == 1 }
        #expect(model.text.isEmpty)
        #expect(model.completedText == nil)
        try newProvider.complete("新选区")
        try await wait { !model.isTranslating }
        #expect(model.completedText == "新选区")
    }

    @Test func changingLanguageEngineOrPolicyInvalidatesCompletedResult() async throws {
        for change in 0..<4 {
            let provider = ControlledSelectionProvider()
            let model = model(for: provider)
            model.translate(using: provider)
            try await wait { provider.requestCount == 1 }
            try provider.complete("Completed")
            try await wait { !model.isTranslating }
            switch change {
            case 0: model.targetLanguage = .japanese
            case 1: model.sourceLanguage = .explicit(.english)
            case 2: model.engineID = "other"
            default: model.networkPolicy = .onDeviceOnly
            }
            #expect(model.completedText == nil)
            #expect(model.text.isEmpty)
        }
    }

    @Test func cancellationAndFailureCannotReplacePartialText() async throws {
        for fails in [false, true] {
            let provider = ControlledSelectionProvider()
            let model = model(for: provider)
            model.translate(using: provider)
            try await wait { provider.requestCount == 1 }
            provider.continuation.yield(.textSnapshot("Partial"))
            try await wait { model.text == "Partial" }
            if fails {
                provider.continuation.finish(throwing: TranslationError.invalidResponse("Test failure"))
                try await wait { !model.isTranslating }
                #expect(model.error != nil)
            } else {
                model.cancel()
                try provider.complete("Late completion")
            }
            #expect(model.completedText == nil)
        }
    }

    @Test func onDevicePolicyPreventsCallingCloudProvider() async throws {
        let provider = ControlledSelectionProvider(location: .cloud)
        let model = model(for: provider)
        model.networkPolicy = .onDeviceOnly
        model.translate(using: provider)
        try await wait { !model.isTranslating }
        #expect(provider.requestCount == 0)
        #expect(model.error != nil)
        #expect(model.completedText == nil)
    }
}

#if os(iOS)
struct SystemTranslationKeychainTests {
    @Test func migratesOldCredentialsAndRemovalDoesNotRestoreThem() throws {
        let sharedGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "TranslationSharedKeychainAccessGroup") as? String)
        let appGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "TranslationLegacyKeychainAccessGroup") as? String)
        let service = "SystemTranslationKeychainTest-\(UUID())"
        let old = KeychainStore(service: service, accessGroup: appGroup)
        let shared = KeychainStore(service: service, accessGroup: sharedGroup)
        let migrating = KeychainStore(service: service, accessGroup: sharedGroup, legacyAccessGroup: appGroup)
        defer { try? migrating.delete(account: "test") }
        try old.set("old-test-key", for: "test")
        #expect(shared.string(for: "test") == nil)
        #expect(migrating.string(for: "test") == "old-test-key")
        #expect(shared.string(for: "test") == "old-test-key")
        try migrating.set("new-test-key", for: "test")
        #expect(shared.string(for: "test") == "new-test-key")
        try old.set("stale-test-key", for: "test")
        try migrating.delete(account: "test")
        #expect(migrating.string(for: "test") == nil)
        #expect(old.string(for: "test") == nil)
    }
}
#endif
