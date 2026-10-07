import Foundation
import Observation
import TranslationCore
import TranslationProviders

/// Knows which engines exist, builds providers from settings + Keychain, and caches
/// availability for the UI. The UI never touches HTTP or model objects directly.
@Observable
@MainActor
final class EngineRegistry {
    struct Engine: Identifiable, Hashable {
        let id: String
        var name: String
        var location: ProcessingLocation
        var availability: ProviderAvailability
    }

    enum KeychainAccount {
        static let anthropic = "anthropic.apiKey"
        static let openAICompatible = "openai-compatible.apiKey"
    }

    private(set) var engines: [Engine] = []
    let settings: AppSettings
    let keychain: KeychainStore

    init(settings: AppSettings, keychain: KeychainStore = .shared) {
        self.settings = settings
        self.keychain = keychain
        engines = Self.knownEngines(settings: settings)
    }

    static func knownEngines(settings: AppSettings) -> [Engine] {
        [
            Engine(id: AppleSystemModelProvider.providerID, name: "Apple Intelligence", location: .onDevice, availability: .unavailable("Checking…")),
            Engine(id: AnthropicProvider.providerID, name: "Anthropic", location: .cloud, availability: .unavailable("Checking…")),
            Engine(
                id: OpenAICompatibleProvider.providerID,
                name: settings.openAIDisplayName.isEmpty ? "OpenAI-compatible" : settings.openAIDisplayName,
                location: .cloud,
                availability: .unavailable("Checking…")
            ),
        ]
    }

    var selectedEngine: Engine? {
        engines.first { $0.id == settings.selectedEngineID } ?? engines.first { $0.availability.isAvailable }
    }

    func select(_ id: String) {
        settings.selectedEngineID = id
    }

    // MARK: - Providers

    func makeProvider(id: String) -> (any TranslationProvider)? {
        switch id {
        case AppleSystemModelProvider.providerID:
            return AppleSystemModelProvider()
        case AnthropicProvider.providerID:
            return AnthropicProvider(configuration: anthropicConfiguration())
        case OpenAICompatibleProvider.providerID:
            return OpenAICompatibleProvider(configuration: openAIConfiguration())
        default:
            return nil
        }
    }

    func anthropicConfiguration() -> AnthropicConfiguration {
        AnthropicConfiguration(
            apiKey: keychain.string(for: KeychainAccount.anthropic) ?? "",
            model: settings.anthropicModel.trimmingCharacters(in: .whitespaces),
            effort: settings.anthropicEffort.isEmpty ? nil : settings.anthropicEffort
        )
    }

    func openAIConfiguration() -> OpenAICompatibleConfiguration {
        let base = URL(string: settings.openAIBaseURL.trimmingCharacters(in: .whitespaces)) ?? URL(string: "https://api.openai.com/v1")!
        return OpenAICompatibleConfiguration(
            displayName: settings.openAIDisplayName.isEmpty ? "OpenAI-compatible" : settings.openAIDisplayName,
            baseURL: base,
            apiKey: keychain.string(for: KeychainAccount.openAICompatible) ?? "",
            model: settings.openAIModel.trimmingCharacters(in: .whitespaces)
        )
    }

    // MARK: - Keys

    func apiKey(for account: String) -> String {
        keychain.string(for: account) ?? ""
    }

    func setAPIKey(_ key: String, for account: String) throws {
        try keychain.set(key, for: account)
    }

    // MARK: - Availability

    func refresh() async {
        var updated = Self.knownEngines(settings: settings)
        for index in updated.indices {
            guard let provider = makeProvider(id: updated[index].id) else { continue }
            updated[index].availability = await provider.availability()
            updated[index].location = provider.capabilities.processingLocation
            updated[index].name = provider.displayName
        }
        engines = updated
        if settings.selectedEngineID.isEmpty, let first = updated.first(where: { $0.availability.isAvailable }) {
            settings.selectedEngineID = first.id
        }
    }

    /// Runs a tiny real request so the user sees the key, endpoint and model actually work.
    func testConnection(engineID: String) async -> Result<String, any Error> {
        guard let provider = makeProvider(id: engineID) else {
            return .failure(TranslationError.invalidResponse("Unknown engine."))
        }
        let availability = await provider.availability()
        guard availability.isAvailable else {
            return .failure(TranslationError.modelNotReady(availability.message ?? "Unavailable."))
        }
        let sample = "Hello, world."
        let target: LanguageCode = settings.targetLanguage == .english ? .simplifiedChinese : settings.targetLanguage
        let request = TranslationRequest(sourceText: sample, sourceLanguage: .explicit(.english), targetLanguage: target)
        do {
            var text = ""
            var model = provider.displayName
            for try await event in TranslationCoordinator().run(request, using: provider) {
                switch event {
                case .text(let t): text = t
                case .started(let name): model = name
                default: break
                }
            }
            return .success("Connected. \(model) translated “\(sample)” → “\(text)”")
        } catch {
            return .failure(error)
        }
    }
}
