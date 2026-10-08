#if os(macOS) || os(visionOS)
import LiveCaptions
import SwiftUI
import TranslationCore
import TranslationProviders
#if canImport(Translation) && !os(visionOS)
import Translation
#endif

/// Control panel for live captions: what to listen to, languages, translation, display.
struct LiveCaptionsView: View {
    @Environment(LiveCaptionsController.self) private var controller
    @Environment(EngineRegistry.self) private var registry
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    #if canImport(Translation) && !os(visionOS)
    @State private var downloadConfiguration: TranslationSession.Configuration?
    #endif

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    statusIcon
                    Text(controller.statusText)
                        .foregroundStyle(statusColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if controller.phase.isActive {
                        Button("Stop", systemImage: "stop.fill") { Task { await controller.stop() } }
                            .accessibilityIdentifier("stopCaptions")
                    } else {
                        Button("Start…", systemImage: "captions.bubble") { Task { await controller.start() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!LiveCaptionsController.isCaptureAvailable)
                            .accessibilityIdentifier("startCaptions")
                    }
                }
            } footer: {
                Text(sourceFootnote)
            }

            Section("Languages") {
                Picker("Spoken language", selection: $controller.spokenLocaleIdentifier) {
                    if controller.supportedLocales.isEmpty {
                        Text(Locale.current.localizedString(forIdentifier: controller.spokenLocaleIdentifier) ?? controller.spokenLocaleIdentifier)
                            .tag(controller.spokenLocaleIdentifier)
                    }
                    ForEach(controller.supportedLocales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                Picker("Translate into", selection: $controller.targetLanguage) {
                    ForEach(LanguageCode.commonTargets) { code in
                        Text(code.displayName()).tag(code)
                    }
                }
            }
            .disabled(controller.phase.isActive)

            Section("Translation") {
                Picker("Translate with", selection: $controller.translator) {
                    ForEach(controller.availableTranslators) { choice in
                        Text(title(for: choice)).tag(choice)
                    }
                }
                .disabled(controller.phase.isActive)
                translationDetail
                if let error = controller.lastTranslationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Display") {
                Toggle("Show original under the translation", isOn: $controller.showsOriginal)
                LabeledContent("Text size") {
                    Slider(value: $controller.textSize, in: 16...56, step: 2)
                        .frame(maxWidth: 220)
                }
                #if os(macOS)
                Toggle("Adjust caption position", isOn: $controller.isAdjustingPosition)
                Text("Captions float at the bottom of the screen, also over full-screen video. Turn this on to drag them elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Captions appear in their own window. Place it under the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section {
                if controller.timeline.lines.isEmpty {
                    Text("Recognized speech appears here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.timeline.lines.suffix(100).reversed()) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.translation ?? line.original)
                            if line.translation != nil {
                                Text(line.original).font(.caption).foregroundStyle(.secondary)
                            } else if line.translationFailed {
                                Text("Not translated").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Transcript")
                    Spacer()
                    Button("Copy") { Pasteboard.copy(controller.timeline.transcript) }
                        .disabled(controller.timeline.lines.isEmpty)
                }
            } footer: {
                Text("Kept only while this window is open. Not saved to history.")
            }
        }
        .formStyle(.grouped)
        .task {
            await registry.refresh()
            await controller.loadLocales()
            await controller.refreshAppleTranslationState()
        }
        .onChange(of: controller.spokenLocaleIdentifier) { Task { await controller.refreshAppleTranslationState() } }
        .onChange(of: controller.targetLanguage) { Task { await controller.refreshAppleTranslationState() } }
        #if canImport(Translation) && !os(visionOS)
        .translationTask(downloadConfiguration) { session in
            try? await session.prepareTranslation()
            await controller.refreshAppleTranslationState()
            downloadConfiguration = nil
        }
        #endif
        #if os(visionOS)
        .onChange(of: controller.phase) { _, phase in
            if phase == .running {
                openWindow(id: "caption-overlay", value: "captions")
            } else if !phase.isActive {
                dismissWindow(id: "caption-overlay", value: "captions")
            }
        }
        #endif
    }

    private var sourceFootnote: String {
        guard LiveCaptionsController.isCaptureAvailable else {
            return "Capturing other apps' sound is not available on this device."
        }
        #if os(macOS)
        return "Start, then pick a Safari window (or any app) in the system picker. Only its sound is used, recognized on this Mac, and nothing is recorded."
        #else
        return "Start, then pick what to share in the system picker. Only the sound is used, recognized on this device, and nothing is recorded."
        #endif
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.phase {
        case .choosingSource, .preparing: ProgressView().controlSize(.small)
        case .running: Image(systemName: "waveform").foregroundStyle(.green).symbolEffect(.variableColor.iterative)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "captions.bubble").foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if case .failed = controller.phase { return .orange }
        return .primary
    }

    private func title(for choice: LiveCaptionsController.TranslatorChoice) -> String {
        switch choice {
        case .appleTranslation:
            return "Apple Translation (fastest, on device)"
        case .engine(let id):
            guard let engine = registry.engines.first(where: { $0.id == id }) else { return id }
            let title = "\(engine.name) (\(engine.location.label.lowercased()))"
            return engine.availability.isAvailable ? title : "\(title) – not available"
        case .off:
            return "Off: show the original only"
        }
    }

    private func engineDetail(for id: String) -> String {
        guard let engine = registry.engines.first(where: { $0.id == id }) else { return "" }
        if let message = engine.availability.message, !engine.availability.isAvailable {
            return message
        }
        if id == AppleSystemModelProvider.providerID {
            return "Each finished sentence is translated by the on-device model, usually within a second or two. Text stays on this device."
        }
        return "Each finished sentence is sent to \(engine.name) with the previous lines as context. Slower than Apple Translation, but understands context."
    }

    @ViewBuilder
    private var translationDetail: some View {
        if !controller.translationNeeded, controller.translator != .off {
            Text("The spoken language and the target language are the same, so captions show the original.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch controller.translator {
            case .appleTranslation:
                appleDetail
            case .engine(let id):
                Text(engineDetail(for: id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .off:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        #if canImport(Translation) && !os(visionOS)
        Button("Download…") {
            // Low-latency models are a separate download from the standard ones.
            downloadConfiguration = TranslationSession.Configuration(
                source: controller.appleSourceLanguage,
                target: controller.appleTargetLanguage,
                preferredStrategy: .lowLatency
            )
        }
        .disabled(controller.phase.isActive)
        #endif
    }

    @ViewBuilder
    private var appleDetail: some View {
        switch controller.appleTranslationState {
        case .readyLowLatency:
            Label("Low-latency models ready. Translations appear while people are still speaking.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .readyStandard:
            HStack {
                Text("Using the standard models: each finished sentence is translated, a little later. Download the low-latency models to also translate while people are still speaking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                downloadButton
            }
        case .needsDownload:
            HStack {
                Text("This language pair needs a one-time download.")
                    .font(.caption)
                Spacer()
                downloadButton
            }
        case .unsupported:
            Text("Apple Translation does not support this language pair. Choose another engine.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unavailable, .unknown:
            EmptyView()
        }
    }
}
#endif
