#if os(iOS)
import ImagePipeline
import SwiftUI
import TranslationCore
import TranslationProviders

/// A single scrolling workspace leaves room for the keyboard and long translations.
struct IOSTranslationView: View {
    @Environment(TranslationWorkspace.self) private var workspace
    @Environment(EngineRegistry.self) private var registry
    @FocusState private var isEditing: Bool
    let layout: TranslationView.Layout

    private var hasOutput: Bool {
        !workspace.translatedText.isEmpty || workspace.phase.isRunning || workspace.lastError != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LanguageBar(isCompact: true, onLanguageChange: translateCurrentInput)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 4)

                if layout == .sideBySide {
                    HStack(alignment: .top, spacing: 24) {
                        sourceCard
                        if hasOutput { translationCard }
                    }
                } else {
                    sourceCard
                    if hasOutput { translationCard }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                ToolbarPasteButton(isEnabled: workspace.clipboardHasContent) { workspace.paste($0) }
            }
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Button("Choose Photo", systemImage: "photo.on.rectangle") {
                        isEditing = false
                        workspace.isPickingPhoto = true
                    }
                    Button("Import Image File", systemImage: "folder") {
                        isEditing = false
                        workspace.isImportingImage = true
                    }
                } label: {
                    Label("Add Image", systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("importImageMenu")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { engineMenu }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                if workspace.phase.isRunning {
                    Button("Stop", systemImage: "stop.fill") { workspace.stop() }
                        .accessibilityIdentifier("stopButton")
                } else {
                    CopyActionButton()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing {
                HStack {
                    Spacer()
                    Button("Translate") {
                        isEditing = false
                        workspace.translate()
                    }
                    .fontWeight(.semibold)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(!workspace.canTranslate)
                    .accessibilityIdentifier("translateButton")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .popover(isPresented: Binding(
            get: { workspace.isShowingContext },
            set: { workspace.isShowingContext = $0 }
        )) { ContextPopover() }
        .popover(isPresented: Binding(
            get: { workspace.isShowingExplain },
            set: { workspace.isShowingExplain = $0 }
        )) { ExplainPopover() }
        .onChange(of: workspace.phase.isRunning) { _, running in
            if running { isEditing = false }
        }
    }

    private var sourceCard: some View {
        @Bindable var workspace = workspace
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Original")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !workspace.sourceText.isEmpty || workspace.attachment != nil {
                    Button("Clear source and translation", systemImage: "xmark.circle.fill") {
                        workspace.clear()
                        isEditing = true
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("clearWorkspaceButton")
                }
            }
            TextField("Enter text", text: $workspace.sourceText, axis: .vertical)
                .font(.title2)
                .lineSpacing(5)
                .lineLimit(4...16)
                .focused($isEditing)
                .accessibilityLabel("Source text")
                .accessibilityIdentifier("sourceEditor")
            if let attachment = workspace.attachment {
                ImageAttachmentView(attachment: attachment) { workspace.removeImage() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .dropDestination(for: DroppedImage.self) { items, _ in
            guard let image = items.first else { return false }
            workspace.importImage(data: image.data, translateWhenDone: true)
            return true
        }
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(workspace.targetLanguage.displayName())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if workspace.phase.isRunning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Translating")
                }
            }
            if let error = workspace.lastError {
                ErrorBanner(message: error.message, suggestion: error.suggestion) {
                    workspace.retry()
                } openSettings: {
                    workspace.isShowingSettings = true
                }
            }
            if !workspace.translatedText.isEmpty {
                Text(workspace.translatedText)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("translationResult")
                ViewThatFits(in: .horizontal) {
                    resultActions.labelStyle(.titleAndIcon)
                    resultActions.labelStyle(.iconOnly)
                }
                .font(.subheadline)
            }
            if let status = workspace.statusMessage, !workspace.phase.isRunning {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if workspace.explanationPhase != .idle { ExplanationView() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var resultActions: some View {
        HStack(spacing: 20) {
            Button("Context", systemImage: "text.bubble") { workspace.isShowingContext = true }
            Button("Explain", systemImage: "questionmark.bubble") { workspace.isShowingExplain = true }
                .disabled(workspace.phase.isRunning)
            Spacer()
            ShareLink(item: workspace.translatedText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
        }
    }

    private var engineMenu: some View {
        Menu {
            Picker("Engine", selection: Binding(
                get: { registry.selectedEngine?.id ?? "" },
                set: { registry.select($0); translateCurrentInput() }
            )) {
                ForEach(registry.engines) { engine in
                    Text(engine.name).tag(engine.id)
                        .disabled(!engine.availability.isAvailable)
                }
            }
        } label: {
            Text(selectedModelName)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 100)
        }
        .accessibilityLabel("Translation model")
        .accessibilityValue(selectedModelName)
        .accessibilityIdentifier("engineMenu")
    }

    private var selectedModelName: String {
        guard let engine = registry.selectedEngine else { return "Choose Model" }
        let model: String
        switch engine.id {
        case AnthropicProvider.providerID: model = registry.settings.anthropicModel
        case OpenAICompatibleProvider.providerID: model = registry.settings.openAIModel
        default: return engine.name
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? engine.name : name
    }

    private func translateCurrentInput() {
        guard !workspace.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        workspace.translate()
    }
}
#endif

#if DEBUG && os(iOS)
private struct IOSWorkspacePreview: View {
    let workspace: TranslationWorkspace
    let registry: EngineRegistry

    init(translated: Bool) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "NativeWorkspacePreview")!)
        settings.sourceLanguage = .explicit(.english)
        settings.targetLanguage = LanguageCode("fr")
        settings.selectedEngineID = AppleSystemModelProvider.providerID
        registry = EngineRegistry(settings: settings)
        workspace = TranslationWorkspace(settings: settings, registry: registry, modelContext: nil)
        if translated {
            let request = TranslationRequest(
                sourceText: "The library opens at nine tomorrow. Bring your notebook and we can plan the journey together.",
                sourceLanguage: .explicit(.english), targetLanguage: LanguageCode("fr")
            )
            let result = TranslationResult(requestID: request.id,
                text: "La bibliothèque ouvre à neuf heures demain. Apportez votre carnet et nous pourrons préparer le voyage ensemble.",
                providerID: "preview", modelName: "Preview", processingLocation: .onDevice)
            workspace.load(HistoryEntry(request: request, result: result))
        }
    }

    var body: some View {
        NavigationStack {
            IOSTranslationView(layout: .stacked)
                .navigationTitle("Translate")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("History", systemImage: "clock") {} }
                    WorkspaceToolbar()
                }
        }
        .environment(workspace)
        .environment(registry)
    }
}

#Preview("iPhone · Empty") { IOSWorkspacePreview(translated: false) }
#Preview("iPhone · Translation") { IOSWorkspacePreview(translated: true) }
#endif
