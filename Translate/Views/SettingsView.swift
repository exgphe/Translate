import SwiftUI
import TranslationCore
import TranslationProviders

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Engines", systemImage: "cpu") { EnginesSettingsView() }
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettingsView() }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

// MARK: - Engines

struct EnginesSettingsView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Default engine", selection: $settings.selectedEngineID) {
                    ForEach(registry.engines) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
            }

            AppleEngineSection()

            AnthropicSection()

            OpenAICompatibleSection()
        }
        .formStyle(.grouped)
        .task { await registry.refresh() }
    }
}

struct AppleEngineSection: View {
    @Environment(EngineRegistry.self) private var registry

    private var engine: EngineRegistry.Engine? {
        registry.engines.first { $0.id == AppleSystemModelProvider.providerID }
    }

    var body: some View {
        Section("Apple Intelligence") {
            LabeledContent("Status") {
                AvailabilityLabel(availability: engine?.availability ?? .unavailable("Checking…"))
            }
            LabeledContent("Processing", value: "On device. Text never leaves this Mac.")
            let languages = AppleSystemModelProvider().supportedLanguages
            if !languages.isEmpty {
                LabeledContent("Languages") {
                    Text(languages.map { $0.displayName() }.joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
            }
            Text("The system model is managed by macOS. It is small, so very long texts must be split. The permissive guardrail profile is used because translation is a content transformation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AnthropicSection: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var test = ConnectionTestState()

    private let modelSuggestions = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"]

    var body: some View {
        @Bindable var settings = settings
        Section("Anthropic") {
            SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                .onSubmit(saveKey)
            HStack {
                Button("Save Key", action: saveKey)
                    .disabled(apiKey.isEmpty)
                Button("Remove Key") {
                    apiKey = ""
                    saveKey()
                }
                .disabled(registry.apiKey(for: EngineRegistry.KeychainAccount.anthropic).isEmpty)
                if let keyStatus {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Model ID", text: $settings.anthropicModel)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                ForEach(modelSuggestions, id: \.self) { suggestion in
                    Button(suggestion) { settings.anthropicModel = suggestion }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            Picker("Effort", selection: $settings.anthropicEffort) {
                Text("Server default").tag("")
                ForEach(AnthropicConfiguration.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
            }
            ConnectionTestRow(state: $test) {
                await registry.testConnection(engineID: AnthropicProvider.providerID)
            }
            Text("Requests go directly from this Mac to api.anthropic.com with your key. Usage is billed to your own account. If Anthropic's safety classifier declines a request it is retried server-side on the fallback model Anthropic recommends.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { apiKey = registry.apiKey(for: EngineRegistry.KeychainAccount.anthropic) }
    }

    private func saveKey() {
        do {
            try registry.setAPIKey(apiKey, for: EngineRegistry.KeychainAccount.anthropic)
            keyStatus = apiKey.isEmpty ? "Key removed." : "Saved to Keychain."
            Task { await registry.refresh() }
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}

struct OpenAICompatibleSection: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var test = ConnectionTestState()

    var body: some View {
        @Bindable var settings = settings
        Section("OpenAI-compatible service") {
            TextField("Display name", text: $settings.openAIDisplayName)
            TextField("Base URL", text: $settings.openAIBaseURL, prompt: Text("https://api.openai.com/v1"))
                .autocorrectionDisabled()
            TextField("Model", text: $settings.openAIModel, prompt: Text("Model name as the service expects it"))
                .autocorrectionDisabled()
            SecureField("API key", text: $apiKey, prompt: Text("Optional for local servers"))
                .onSubmit(saveKey)
            HStack {
                Button("Save Key", action: saveKey)
                    .disabled(apiKey.isEmpty)
                Button("Remove Key") {
                    apiKey = ""
                    saveKey()
                }
                .disabled(registry.apiKey(for: EngineRegistry.KeychainAccount.openAICompatible).isEmpty)
                if let keyStatus {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            ConnectionTestRow(state: $test) {
                await registry.testConnection(engineID: OpenAICompatibleProvider.providerID)
            }
            Text("Works with any Chat Completions endpoint: OpenAI, OpenRouter, DeepSeek, Gemini's compatibility API, or a local server such as Ollama or LM Studio. A localhost address is shown as “Local server”; everything else as “Cloud”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { apiKey = registry.apiKey(for: EngineRegistry.KeychainAccount.openAICompatible) }
    }

    private func saveKey() {
        do {
            try registry.setAPIKey(apiKey, for: EngineRegistry.KeychainAccount.openAICompatible)
            keyStatus = apiKey.isEmpty ? "Key removed." : "Saved to Keychain."
            Task { await registry.refresh() }
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}

struct ConnectionTestState {
    var isRunning = false
    var message: String?
    var succeeded = false
}

struct ConnectionTestRow: View {
    @Binding var state: ConnectionTestState
    let run: () async -> Result<String, any Error>

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button("Test Connection") {
                state.isRunning = true
                state.message = nil
                Task {
                    let result = await run()
                    switch result {
                    case .success(let message):
                        state.succeeded = true
                        state.message = message
                    case .failure(let error):
                        state.succeeded = false
                        state.message = (error as? TranslationError)?.errorDescription ?? error.localizedDescription
                    }
                    state.isRunning = false
                }
            }
            .disabled(state.isRunning)
            if state.isRunning { ProgressView().controlSize(.small) }
            if let message = state.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.succeeded ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
    }
}

struct AvailabilityLabel: View {
    let availability: ProviderAvailability

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(availability.isAvailable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(availability.message ?? "Available")
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Languages") {
                Picker("Default target language", selection: $settings.targetLanguage) {
                    ForEach(LanguageCode.commonTargets) { code in
                        Text(code.displayName()).tag(code)
                    }
                }
                Text("The language bar remembers your last choice. Source language is detected on device unless you pick one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                KeyboardHintRow(action: "Translate", shortcut: "⌘↩")
                KeyboardHintRow(action: "Stop", shortcut: "⌘.")
                KeyboardHintRow(action: "Paste and translate", shortcut: "⇧⌘V")
                KeyboardHintRow(action: "Copy translation", shortcut: "⇧⌘C")
                KeyboardHintRow(action: "Import image", shortcut: "⇧⌘I")
                KeyboardHintRow(action: "Add context", shortcut: "⇧⌘K")
                KeyboardHintRow(action: "Explain", shortcut: "⇧⌘E")
            }
        }
        .formStyle(.grouped)
    }
}

struct KeyboardHintRow: View {
    let action: LocalizedStringKey
    let shortcut: String

    var body: some View {
        LabeledContent(action) {
            Text(shortcut).monospaced().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var isConfirmingClear = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Where text goes") {
                Toggle("Only translate on this device", isOn: $settings.onDeviceOnly)
                Text("When on, cloud and local-server engines are refused before any request is made. The app never switches from on-device to cloud by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Images") {
                Text("Images are recognized on device with Vision. Only the recognized text is sent to the engine you chose. Images are not saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Save translations to history", isOn: $settings.historyEnabled)
                Text("History is stored locally in the app's container and is never used as context for new requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete All History…", role: .destructive) { isConfirmingClear = true }
            }
            Section("Keys") {
                Text("API keys are stored in the macOS Keychain for this app only and are never written to logs, exports, or history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all history?", isPresented: $isConfirmingClear) {
            Button("Delete All", role: .destructive) { model.deleteAllHistory() }
        }
    }
}
