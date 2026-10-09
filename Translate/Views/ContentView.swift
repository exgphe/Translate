import SwiftData
import SwiftUI
import TranslationCore
import UniformTypeIdentifiers
#if !os(macOS)
import PhotosUI
#endif

/// Root layout. Regular widths (Mac, iPad) get a history sidebar beside the workspace;
/// compact widths (iPhone, narrow iPad windows) get a stack with history pushed on demand.
struct ContentView: View {
    @Environment(TranslationWorkspace.self) private var workspace
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var photoItem: PhotosPickerItem?
    #endif
    @State private var selectedEntryID: UUID?

    private var isCompact: Bool {
        #if os(macOS)
        false
        #else
        sizeClass == .compact
        #endif
    }

    var body: some View {
        @Bindable var workspace = workspace
        Group {
            if isCompact {
                CompactRoot(selectedEntryID: $selectedEntryID)
            } else {
                SplitRoot(selectedEntryID: $selectedEntryID)
            }
        }
        .fileImporter(
            isPresented: $workspace.isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                workspace.importImage(url: url)
            }
        }
        #if !os(macOS)
        .photosPicker(isPresented: $workspace.isPickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    workspace.importImage(data: data)
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $workspace.isShowingSettings) {
            SettingsView()
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $workspace.isShowingLiveCaptions) {
            NavigationStack {
                LiveCaptionsView()
                    .navigationTitle("Live Captions")
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { workspace.isShowingLiveCaptions = false }
                        }
                    }
            }
            .environment(model.liveCaptions)
            .environment(model.registry)
        }
        #endif
        .task(id: "\(scenePhase)-\(settings.autoPasteEnabled)") {
            guard needsClipboardWatch, shouldWatchClipboard else { return }
            while !Task.isCancelled {
                workspace.clipboardTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: selectedEntryID) { _, newValue in
            guard let newValue else { return }
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == newValue })
            if let entry = try? model.container.mainContext.fetch(descriptor).first {
                workspace.load(entry)
            }
        }
        .onChange(of: workspace.sourceText) { _, _ in
            // Editing the source detaches the view from the selected history row.
            if selectedEntryID != nil, workspace.lastRequest?.id != selectedEntryID { selectedEntryID = nil }
        }
    }
}

extension ContentView {
    /// iPhone and iPad only read the pasteboard while frontmost. On visionOS and macOS the
    /// window stays visible beside other apps, so keep watching unless it is in the background.
    /// iOS and visionOS always watch so the Paste button can turn gray when there is nothing
    /// to paste (type checks only, no prompt). macOS grays its button by itself.
    fileprivate var needsClipboardWatch: Bool {
        #if os(macOS)
        settings.autoPasteEnabled
        #else
        true
        #endif
    }

    fileprivate var shouldWatchClipboard: Bool {
        #if os(iOS)
        scenePhase == .active
        #else
        scenePhase != .background
        #endif
    }
}

// MARK: - Regular width

struct SplitRoot: View {
    @Binding var selectedEntryID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HistorySidebar(selection: $selectedEntryID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            TranslationView(layout: .sideBySide)
                .navigationTitle("Translate")
                .toolbarTitleDisplayMode(.inline)
                .toolbar { WorkspaceToolbar() }
        }
    }
}

// MARK: - Compact width

struct CompactRoot: View {
    @Environment(TranslationWorkspace.self) private var workspace
    @Binding var selectedEntryID: UUID?

    var body: some View {
        @Bindable var workspace = workspace
        NavigationStack {
            TranslationView(layout: .stacked)
                .navigationTitle("Translate")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("History", systemImage: "clock") { workspace.isShowingHistory = true }
                            .accessibilityIdentifier("historyButton")
                    }
                    WorkspaceToolbar()
                }
                .navigationDestination(isPresented: $workspace.isShowingHistory) {
                    HistorySidebar(selection: $selectedEntryID) { entry in
                        workspace.load(entry)
                        workspace.isShowingHistory = false
                    }
                }
        }
    }
}

// MARK: - Shared toolbar

struct WorkspaceToolbar: ToolbarContent {
    @Environment(TranslationWorkspace.self) private var workspace
    #if os(macOS) || os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Import Image", systemImage: "photo.badge.plus") { workspace.isImportingImage = true }
                .help("Import an image and recognize its text on device (⇧⌘I)")
            Button("Clear", systemImage: "trash") { workspace.clear() }
                .help("Clear source and translation (⌘K)")
                .disabled(workspace.sourceText.isEmpty && workspace.translatedText.isEmpty)
            Button("Live Captions", systemImage: "captions.bubble") { openWindow(id: "live-captions") }
                .help("Translate what another app is playing, as live captions (⌥⌘L)")
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Choose Photo", systemImage: "photo.on.rectangle") { workspace.isPickingPhoto = true }
                Button("Import Image File", systemImage: "folder") { workspace.isImportingImage = true }
                #if os(visionOS)
                Button("Live Captions", systemImage: "captions.bubble") { openWindow(id: "live-captions", value: "main") }
                #else
                Button("Live Captions", systemImage: "captions.bubble") { workspace.isShowingLiveCaptions = true }
                #endif
                Divider()
                Button("Clear", systemImage: "trash", role: .destructive) { workspace.clear() }
                    .disabled(workspace.sourceText.isEmpty && workspace.translatedText.isEmpty)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            Button("Settings", systemImage: "gearshape") { workspace.isShowingSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
        #endif
    }
}
