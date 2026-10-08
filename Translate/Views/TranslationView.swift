import ImagePipeline
import SwiftUI
import TranslationCore

/// The translation screen: language bar, source and translation panes, execution bar.
/// Panes sit side by side in regular widths and stack vertically in compact widths.
struct TranslationView: View {
    enum Layout { case sideBySide, stacked }

    @Environment(TranslationWorkspace.self) private var workspace
    var layout: Layout = .sideBySide

    var body: some View {
        VStack(spacing: 0) {
            LanguageBar(isCompact: layout == .stacked)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if layout == .sideBySide {
                HStack(spacing: 0) {
                    SourcePane()
                    Divider()
                    TranslationPane()
                }
            } else {
                VStack(spacing: 0) {
                    SourcePane()
                    Divider()
                    TranslationPane()
                }
            }
            #if !os(visionOS)
            Divider()
            ExecutionBar(isCompact: layout == .stacked)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            #endif
        }
        #if os(visionOS)
        // Controls float below the window, where gaze targeting is comfortable.
        .toolbar { VisionOrnamentControls() }
        #else
        .background(.background)
        #endif
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

// MARK: - Language bar

struct LanguageBar: View {
    @Environment(TranslationWorkspace.self) private var workspace
    var isCompact = false

    private var sourceOptions: [LanguageCode] {
        var codes = LanguageCode.commonTargets
        if let explicit = workspace.sourceLanguage.explicitCode, !codes.contains(explicit) { codes.insert(explicit, at: 0) }
        return codes
    }

    private var targetOptions: [LanguageCode] {
        var codes = LanguageCode.commonTargets
        if !codes.contains(workspace.targetLanguage) { codes.insert(workspace.targetLanguage, at: 0) }
        return codes
    }

    var body: some View {
        @Bindable var workspace = workspace
        HStack(spacing: isCompact ? 4 : 12) {
            languageMenu(title: detectedLabel, accessibilityID: "sourceLanguage") {
                Picker("Source", selection: $workspace.sourceLanguage) {
                    Text(detectedLabel).tag(SourceLanguage.automatic)
                    Divider()
                    ForEach(sourceOptions) { code in
                        Text(code.displayName()).tag(SourceLanguage.explicit(code))
                    }
                }
            }

            Button {
                workspace.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(!workspace.canSwapLanguages)
            .help("Swap languages (⌃⌘S)")
            .accessibilityLabel("Swap languages")

            languageMenu(title: workspace.targetLanguage.displayName(), accessibilityID: "targetLanguage") {
                Picker("Target", selection: $workspace.targetLanguage) {
                    ForEach(targetOptions) { code in
                        Text(code.displayName()).tag(code)
                    }
                }
            }

            if !isCompact { Spacer() }
        }
    }

    /// Regular widths use the native picker; compact widths wrap it in a menu with a
    /// single-line label so long language names truncate instead of wrapping.
    @ViewBuilder
    private func languageMenu<Content: View>(title: String, accessibilityID: String, @ViewBuilder content: () -> Content) -> some View {
        if isCompact {
            Menu {
                content().pickerStyle(.inline).labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(accessibilityID)
        } else {
            content()
                .labelsHidden()
                .frame(maxWidth: 240)
                .accessibilityIdentifier(accessibilityID)
        }
    }

    private var detectedLabel: String {
        if let detected = workspace.detectedLanguage {
            return "Detected: \(detected.displayName())"
        }
        return "Detect language"
    }
}

// MARK: - Source

struct SourcePane: View {
    @Environment(TranslationWorkspace.self) private var workspace
    @State private var isDropTargeted = false
    @FocusState private var isEditing: Bool

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Source") {
                if !workspace.sourceText.isEmpty {
                    Text("\(workspace.sourceText.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $workspace.sourceText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($isEditing)
                    .accessibilityLabel("Source text")
                    .accessibilityIdentifier("sourceEditor")
                    #if os(iOS)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Translate") {
                                isEditing = false
                                workspace.translate()
                            }
                            .disabled(!workspace.canTranslate)
                            Button("Done") { isEditing = false }
                        }
                    }
                    #endif
                if workspace.sourceText.isEmpty {
                    Text("Type or paste text, or drop an image here.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            if let attachment = workspace.attachment {
                Divider()
                ImageAttachmentView(attachment: attachment) { workspace.removeImage() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: DroppedImage.self) { items, _ in
            guard let item = items.first else { return false }
            workspace.importImage(data: item.data)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }
}

struct ImageAttachmentView: View {
    let attachment: TranslationWorkspace.ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(decorative: attachment.image.cgImage, scale: 1, orientation: Image.Orientation(attachment.image.orientation))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160, maxHeight: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                switch attachment.phase {
                case .running:
                    Label("Recognizing text on device…", systemImage: "text.viewfinder")
                case .completed:
                    if let document = attachment.document {
                        Label("\(document.lines.count) lines recognized on device", systemImage: "checkmark.circle")
                        if document.averageConfidence < 0.6 {
                            Text("Low confidence. Check the text before translating.")
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("Only the recognized text is sent to the engine. The image stays on this device.")
                        .foregroundStyle(.secondary)
                case .failed(let message, let suggestion):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if let suggestion { Text(suggestion).foregroundStyle(.secondary) }
                case .idle:
                    EmptyView()
                }
            }
            .font(.caption)
            Spacer()
            Button("Remove", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

// MARK: - Translation

struct TranslationPane: View {
    @Environment(TranslationWorkspace.self) private var workspace
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Translation") {
                if let result = workspace.lastResult {
                    Text("\(result.modelName) · \(result.processingLocation.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if workspace.phase.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(workspace.statusMessage ?? "Translating…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = workspace.lastError {
                        ErrorBanner(message: error.message, suggestion: error.suggestion) {
                            workspace.retry()
                        } openSettings: {
                            #if os(macOS)
                            openSettings()
                            #else
                            workspace.isShowingSettings = true
                            #endif
                        }
                    }
                    if workspace.translatedText.isEmpty, workspace.lastError == nil, !workspace.phase.isRunning {
                        Text("The translation appears here.")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(workspace.translatedText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Translation")
                    }
                    if let status = workspace.statusMessage, !workspace.phase.isRunning {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if workspace.explanationPhase != .idle {
                        ExplanationView()
                    }
                }
                .padding(13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    let suggestion: String?
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let suggestion {
                Text(suggestion).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Retry", action: retry)
                Button("Open Settings…", action: openSettings)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ExplanationView: View {
    @Environment(TranslationWorkspace.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Explanation").font(.headline)
                if workspace.explanationPhase.isRunning { ProgressView().controlSize(.mini) }
            }
            switch workspace.explanationPhase {
            case .failed(let message, _):
                Text(message).foregroundStyle(.orange)
            default:
                Text(workspace.explanation)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ExplainPopover: View {
    @Environment(TranslationWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 10) {
            Text("Explain the translation").font(.headline)
            TextField("Phrase to focus on (optional)", text: $workspace.explanationFocus)
                .textFieldStyle(.roundedBorder)
                .onSubmit { run() }
            Text("Asks the current engine about idioms, tone, ambiguity, and alternatives. Uses the same engine and data path as the translation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Explain") { run() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .popoverSize(width: 340)
    }

    private func run() {
        workspace.isShowingExplain = false
        workspace.explain()
    }
}

struct ContextPopover: View {
    @Environment(TranslationWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 10) {
            Text("Context for this translation").font(.headline)
            TextEditor(text: $workspace.context)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Text("Audience, tone, what names refer to, preferred terms. Sent along with the text; never saved to history on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Clear") { workspace.context = "" }
                    .disabled(workspace.context.isEmpty)
                Spacer()
                Button("Translate with Context") {
                    workspace.isShowingContext = false
                    workspace.translate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!workspace.canTranslate)
            }
        }
        .padding()
        .popoverSize(width: 380)
    }
}

// MARK: - Action bar
//
// One grouping on every platform: engine | clipboard in and out | ask the AI | primary action.
// macOS and iPad show it as a bottom bar, iPhone splits it over two rows, and visionOS floats it
// in a bottom ornament.

/// Engine menu with a one-line note on where the text goes.
struct EngineSummary: View {
    @Environment(EngineRegistry.self) private var registry
    var captionFont: Font = .caption

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            EnginePicker()
            if let engine = registry.selectedEngine {
                Text(engine.locationDescription)
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// Paste (system button, so iOS and visionOS never show the paste prompt) and Copy.
struct ClipboardButtons: View {
    @Environment(TranslationWorkspace.self) private var workspace

    var body: some View {
        PasteButton(payloadType: PastedContent.self) { items in
            workspace.paste(items)
        }
        #if os(visionOS)
        // Ornament items default to icon-only; Paste keeps its title there. Elsewhere the bar
        // decides, so the iPhone row can fall back to icons.
        .labelStyle(.titleAndIcon)
        #endif
        #if !os(macOS)
        // The system button only dims when there is nothing to paste; gray makes that obvious.
        // macOS already draws its disabled push button gray.
        .tint(workspace.clipboardHasContent ? Color.accentColor : Color.gray)
        #endif
        .help("Paste and translate (⇧⌘V)")
        .accessibilityIdentifier("pasteButton")

        Button("Copy", systemImage: "doc.on.doc") { workspace.copyTranslation() }
            .disabled(workspace.translatedText.isEmpty)
            .help("Copy translation (⇧⌘C)")
            .accessibilityIdentifier("copyButton")
    }
}

/// Follow-ups that ask the engine: add context before translating, explain afterwards.
struct AssistButtons: View {
    @Environment(TranslationWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        Button("Context", systemImage: workspace.context.isEmpty ? "text.bubble" : "text.bubble.fill") {
            workspace.isShowingContext = true
        }
        .popover(isPresented: $workspace.isShowingContext, arrowEdge: popoverEdge) { ContextPopover() }
        .help("Tell the engine about audience, tone, or terminology (⇧⌘K)")

        Button("Explain", systemImage: "questionmark.bubble") { workspace.isShowingExplain = true }
            .disabled(workspace.translatedText.isEmpty || workspace.phase.isRunning)
            .popover(isPresented: $workspace.isShowingExplain, arrowEdge: popoverEdge) { ExplainPopover() }
            .help("Ask the engine about idioms, tone, or a specific phrase (⇧⌘E)")
    }

    private var popoverEdge: Edge {
        #if os(macOS)
        .top
        #else
        .bottom
        #endif
    }
}

/// Translate, or Stop while a request runs. Always shows its title.
struct PrimaryActionButton: View {
    @Environment(TranslationWorkspace.self) private var workspace

    var body: some View {
        if workspace.phase.isRunning {
            Button("Stop", systemImage: "stop.fill") { workspace.stop() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityIdentifier("stopButton")
        } else {
            Button("Translate", systemImage: "arrow.right") { workspace.translate() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!workspace.canTranslate)
                .accessibilityIdentifier("translateButton")
        }
    }
}

/// Thin vertical rule between groups (ToolbarSpacer is unavailable on visionOS).
struct GroupSeparator: View {
    var height: CGFloat = 18

    var body: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(width: 1, height: height)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

/// Bottom bar for macOS, iPad, and iPhone.
struct ExecutionBar: View {
    var isCompact = false

    private var compactActions: some View {
        HStack(spacing: 10) {
            ClipboardButtons()
            GroupSeparator()
            AssistButtons()
        }
    }

    var body: some View {
        if isCompact {
            // iPhone: action groups on top, engine and the primary button within thumb reach.
            VStack(spacing: 10) {
                // Titles when they fit; icons only at large text sizes or on narrow phones.
                ViewThatFits(in: .horizontal) {
                    compactActions.labelStyle(.titleAndIcon)
                    compactActions.labelStyle(.iconOnly)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    EngineSummary(captionFont: .caption2)
                    Spacer(minLength: 8)
                    PrimaryActionButton()
                }
            }
            .buttonStyle(.borderless)
        } else {
            HStack(spacing: 8) {
                EngineSummary()
                GroupSeparator()
                Group {
                    ClipboardButtons()
                    GroupSeparator()
                    AssistButtons()
                }
                .labelStyle(.titleAndIcon)
                Spacer(minLength: 12)
                PrimaryActionButton()
            }
            .buttonStyle(.borderless)
        }
    }
}

extension EngineRegistry.Engine {
    /// One-line answer to "where does my text go?", shown next to the engine everywhere.
    var locationDescription: String {
        switch location {
        case .onDevice: "Text stays on this device."
        case .localServer: "Text goes to your local server."
        case .cloud: "Text is sent to \(name) using your own key."
        }
    }
}

#if os(visionOS)
/// visionOS bottom ornament: the same groups as glass toolbar buttons floating below the
/// window, away from its edge where gaze targeting is hard.
struct VisionOrnamentControls: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomOrnament) {
            EngineSummary(captionFont: .caption2)
                .padding(.horizontal, 8)
        }
        ToolbarItem(placement: .bottomOrnament) { GroupSeparator(height: 28) }
        ToolbarItemGroup(placement: .bottomOrnament) { ClipboardButtons() }
        ToolbarItem(placement: .bottomOrnament) { GroupSeparator(height: 28) }
        ToolbarItemGroup(placement: .bottomOrnament) { AssistButtons() }
        ToolbarItem(placement: .bottomOrnament) { GroupSeparator(height: 28) }
        ToolbarItemGroup(placement: .bottomOrnament) { PrimaryActionButton() }
    }
}
#endif

struct EnginePicker: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Menu {
            ForEach(registry.engines) { engine in
                Button {
                    registry.select(engine.id)
                } label: {
                    HStack {
                        Text(engine.name)
                        if let message = engine.availability.message {
                            Text("— \(message)")
                        }
                    }
                }
                .disabled(!engine.availability.isAvailable)
            }
            Divider()
            Button("Refresh Availability") {
                Task { await registry.refresh() }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(registry.selectedEngine?.name ?? "Choose Engine")
                Image(systemName: registry.selectedEngine?.location == .onDevice ? "lock.laptopcomputer" : "cloud")
                    .foregroundStyle(.secondary)
            }
        }
        .compactMenuStyle()
        .fixedSize()
        .help("Choose which model translates. Availability is checked on this device.")
    }

    private var statusColor: Color {
        guard let engine = registry.selectedEngine else { return .gray }
        return engine.availability.isAvailable ? .green : .orange
    }
}

// MARK: - Shared

struct PaneHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
