import SwiftUI
import TranslationCore
import TranslationUIProvider

struct SelectedTextTranslationView: View {
    let context: any TranslationUIProviderContext
    @State private var translation = SelectedTextTranslation()
    @State private var registry: EngineRegistry?
    @State private var isLoading = true
    @State private var showsSource = false
    @State private var configurationMessage: String?

    private var selectedText: String {
        context.inputText.map { String($0.characters) } ?? ""
    }

    private var selectedEngine: EngineRegistry.Engine? {
        registry?.engines.first { $0.id == translation.engineID }
    }

    private var canTranslate: Bool {
        !isLoading && !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedEngine?.availability.isAvailable == true
            && !(translation.networkPolicy == .onDeviceOnly && selectedEngine?.location.leavesDevice == true)
    }

    private var replacement: String? {
        guard context.allowsReplacement, selectedText == translation.input else { return nil }
        return translation.completedText
    }

    var body: some View {
        @Bindable var translation = translation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Translate", systemImage: "character.bubble")
                        .font(.headline)
                    Spacer()
                    Button { context.expandSheet() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Expand translation")
                    Button("Done") { finish(nil) }
                }

                HStack {
                    Picker("From", selection: $translation.sourceLanguage) {
                        Text("Detect language").tag(SourceLanguage.automatic)
                        ForEach(sourceLanguages) { code in
                            Text(code.displayName()).tag(SourceLanguage.explicit(code))
                        }
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("To", selection: $translation.targetLanguage) {
                        ForEach(targetLanguages) { code in
                            Text(code.displayName()).tag(code)
                        }
                    }
                }
                .labelsHidden()
                .disabled(isLoading)

                if let registry {
                    Picker("Engine", selection: $translation.engineID) {
                        if translation.engineID.isEmpty { Text("Choose an engine").tag("") }
                        ForEach(registry.engines) { engine in
                            Text(engine.name).tag(engine.id)
                        }
                    }
                    .disabled(isLoading)
                }

                DisclosureGroup("Selected text", isExpanded: $showsSource) {
                    Text(context.inputText ?? AttributedString("No text selected."))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !translation.text.isEmpty {
                    Text(translation.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("systemTranslationResult")
                } else if !translation.isTranslating {
                    Text("Choose a language and tap Translate.")
                        .foregroundStyle(.secondary)
                }

                if isLoading || translation.isTranslating {
                    HStack {
                        ProgressView()
                        Text(isLoading ? "Checking engines…" : "Translating…")
                    }
                    .font(.callout)
                }
                if let error = translation.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if let message = configurationMessage ?? selectedEngine?.availability.message {
                    Text(message + " Open Translate › Settings › Engines to configure translation.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text(processingDescription)
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    if translation.isTranslating {
                        Button("Stop") { translation.cancel() }
                    } else {
                        Button(translation.error == nil ? "Translate" : "Retry") {
                            guard let provider = registry?.makeProvider(id: translation.engineID) else { return }
                            translation.translate(using: provider)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canTranslate)
                    }
                    if let text = translation.completedText {
                        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    Spacer()
                    if context.allowsReplacement {
                        Button("Replace") {
                            guard let replacement else { return }
                            finish(AttributedString(replacement))
                        }
                        .buttonStyle(.bordered)
                        .disabled(replacement == nil)
                    }
                }
            }
            .padding()
        }
        // A host may reuse its context for another selection. Reset even if only the
        // attributed input changed, and cancel work when its sheet goes away.
        .task(id: context.inputText) { await loadConfiguration() }
        .onDisappear { translation.cancel() }
    }

    private var sourceLanguages: [LanguageCode] {
        languages(including: translation.sourceLanguage.explicitCode)
    }

    private var targetLanguages: [LanguageCode] {
        languages(including: translation.targetLanguage)
    }

    private func languages(including code: LanguageCode?) -> [LanguageCode] {
        var languages = LanguageCode.commonTargets
        if let code, !languages.contains(code) { languages.append(code) }
        return languages
    }

    private var processingDescription: String {
        if translation.networkPolicy == .onDeviceOnly {
            return "Only on-device translation is allowed. Cloud and local-server engines are blocked."
        }
        if selectedEngine?.location.leavesDevice == true {
            return "Selected text is sent to the engine you chose when you tap Translate. It is not saved to history."
        }
        return "Translation runs on this device. Selected text is not saved to history."
    }

    private func loadConfiguration() async {
        translation.invalidate()
        translation.input = selectedText
        isLoading = true
        configurationMessage = nil
        guard let defaults = AppSettings.translationServiceDefaults else {
            registry = nil
            isLoading = false
            configurationMessage = "Shared settings are unavailable."
            return
        }
        // The sheet's choices are temporary; it never changes the app's defaults.
        let settings = AppSettings(defaults: defaults)
        let registry = EngineRegistry(settings: settings)
        self.registry = registry
        translation.sourceLanguage = settings.sourceLanguage
        translation.targetLanguage = settings.targetLanguage
        translation.networkPolicy = settings.networkPolicy
        translation.engineID = settings.selectedEngineID
        await registry.refresh(selectDefault: false)
        guard !Task.isCancelled else { return }
        if translation.engineID.isEmpty { translation.engineID = registry.selectedEngine?.id ?? "" }
        isLoading = false
    }

    private func finish(_ replacement: AttributedString?) {
        translation.cancel()
        context.finish(translation: replacement)
    }
}
