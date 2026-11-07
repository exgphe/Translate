import SwiftUI
import TranslationCore
import TranslationUIProvider

struct SelectedTextTranslationView: View {
    let context: any TranslationUIProviderContext
    @State private var translation = SelectedTextTranslation()
    @State private var registry: EngineRegistry?
    @State private var isLoading = true
    @State private var showsFullSource = false
    @State private var configurationMessage: String?

    private var selectedText: String {
        context.inputText.map { String($0.characters) } ?? ""
    }

    private var selectedEngine: EngineRegistry.Engine? {
        registry?.engines.first { $0.id == translation.engineID }
    }

    private var automaticRequest: SelectedTextTranslation.RequestIdentity? {
        guard !isLoading, selectedText == translation.input, registry != nil else { return nil }
        return translation.requestIdentity
    }

    private var replacement: String? {
        guard context.allowsReplacement, selectedText == translation.input else { return nil }
        return translation.completedText
    }

    var body: some View {
        // The host supplies the title, close button, and sheet detents.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    sourceSection
                    Divider()
                    translationSection
                }
                .padding(18)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))

                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .task(id: context.inputText) { await loadConfiguration() }
        .task(id: automaticRequest) {
            guard automaticRequest != nil,
                  let provider = registry?.makeProvider(id: translation.engineID) else { return }
            translation.translateAutomatically(using: provider)
        }
        .onDisappear { translation.cancel() }
    }

    private var sourceSection: some View {
        @Bindable var translation = translation
        return VStack(alignment: .leading, spacing: 8) {
            Menu {
                Picker("Source language", selection: $translation.sourceLanguage) {
                    Text("Detect language").tag(SourceLanguage.automatic)
                    ForEach(sourceLanguages) { code in
                        Text(code.displayName()).tag(SourceLanguage.explicit(code))
                    }
                }
            } label: {
                languageLabel(sourceLabel)
                    .foregroundStyle(.secondary)
            }
            .disabled(isLoading)
            .accessibilityLabel("Source language")
            .accessibilityValue(sourceLabel)

            Text(selectedText.isEmpty ? "No text selected." : selectedText)
                .font(.body)
                .lineSpacing(4)
                .lineLimit(showsFullSource ? nil : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("systemTranslationSource")
            if !selectedText.isEmpty {
                Button(showsFullSource ? "Show Less" : "Show More") {
                    showsFullSource.toggle()
                    if showsFullSource { context.expandSheet() }
                }
                .font(.caption)
            }
        }
    }

    private var translationSection: some View {
        @Bindable var translation = translation
        return VStack(alignment: .leading, spacing: 12) {
            Menu {
                Picker("Target language", selection: $translation.targetLanguage) {
                    ForEach(targetLanguages) { code in
                        Text(code.displayName()).tag(code)
                    }
                }
            } label: {
                languageLabel(translation.targetLanguage.displayName())
            }
            .disabled(isLoading)
            .accessibilityLabel("Target language")
            .accessibilityValue(translation.targetLanguage.displayName())

            if !translation.text.isEmpty {
                Text(translation.text)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("systemTranslationResult")
            }
            if isLoading || translation.isTranslating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Translating")
            }
            if let message = configurationMessage ?? translation.error {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow.labelStyle(.titleAndIcon)
            actionRow.labelStyle(.iconOnly)
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    }

    private var actionRow: some View {
        @Bindable var translation = translation
        return HStack(spacing: 20) {
            if let registry {
                Menu {
                    Picker("Engine", selection: $translation.engineID) {
                        ForEach(registry.engines) { engine in
                            Text(engine.name).tag(engine.id)
                        }
                    }
                } label: {
                    Label(selectedEngine?.name ?? "Engine", systemImage: "cpu")
                        .lineLimit(1)
                }
                .disabled(isLoading)
            }
            Spacer(minLength: 0)
            if translation.isTranslating {
                Button("Stop", systemImage: "stop.fill") { translation.cancel() }
            } else if !isLoading, translation.completedText == nil, !selectedText.isEmpty {
                Button("Retry", systemImage: "arrow.clockwise") {
                    guard let provider = registry?.makeProvider(id: translation.engineID) else { return }
                    translation.translate(using: provider)
                }
                .disabled(registry == nil)
            }
            if let text = translation.completedText {
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    .labelStyle(.iconOnly)
            }
            if let replacement {
                Button("Replace") { finish(AttributedString(replacement)) }
                    .fontWeight(.semibold)
            }
        }
    }

    private func languageLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
        }
        .font(.caption.weight(.medium))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceLabel: String {
        if let explicit = translation.sourceLanguage.explicitCode { return explicit.displayName() }
        if let detected = translation.detectedLanguage { return "Detected: \(detected.displayName())" }
        return "Detect language"
    }

    private var sourceLanguages: [LanguageCode] { languages(including: translation.sourceLanguage.explicitCode) }
    private var targetLanguages: [LanguageCode] { languages(including: translation.targetLanguage) }

    private func languages(including code: LanguageCode?) -> [LanguageCode] {
        var languages = LanguageCode.commonTargets
        if let code, !languages.contains(code) { languages.append(code) }
        return languages
    }

    private func loadConfiguration() async {
        translation.invalidate()
        translation.input = selectedText
        showsFullSource = false
        isLoading = true
        configurationMessage = nil
        guard let defaults = AppSettings.translationServiceDefaults else {
            registry = nil
            isLoading = false
            configurationMessage = "Open Translate to set up translation."
            return
        }
        // Language/engine choices in this sheet do not change the app's defaults.
        let settings = AppSettings(defaults: defaults)
        let registry = EngineRegistry(settings: settings)
        self.registry = registry
        translation.sourceLanguage = settings.sourceLanguage
        translation.targetLanguage = settings.targetLanguage
        translation.networkPolicy = settings.networkPolicy
        translation.engineID = settings.selectedEngineID
        await registry.refresh(selectDefault: false)
        guard !Task.isCancelled else { return }
        if translation.engineID.isEmpty {
            // With no configured engine, prefer on-device; never silently pick a cloud service.
            translation.engineID = registry.engines.first { $0.location == .onDevice }?.id ?? ""
        }
        isLoading = false
    }

    private func finish(_ replacement: AttributedString?) {
        translation.cancel()
        context.finish(translation: replacement)
    }
}
