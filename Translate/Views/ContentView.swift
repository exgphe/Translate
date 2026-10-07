import SwiftData
import SwiftUI
import TranslationCore
import UniformTypeIdentifiers

/// Root layout: collapsible history sidebar + translation workspace.
struct ContentView: View {
    @Environment(TranslationWorkspace.self) private var workspace
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedEntryID: UUID?

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HistorySidebar(selection: $selectedEntryID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            TranslationView()
                .navigationTitle("Translate")
                .toolbar { toolbarContent }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.isImportingImage = true
            } label: {
                Label("Import Image", systemImage: "photo.badge.plus")
            }
            .help("Import an image and recognize its text on device (⇧⌘I)")

            Button {
                workspace.pasteAndTranslate()
            } label: {
                Label("Paste and Translate", systemImage: "doc.on.clipboard")
            }
            .help("Paste text or an image from the clipboard and translate (⇧⌘V)")

            Button {
                workspace.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear source and translation (⌘K)")
            .disabled(workspace.sourceText.isEmpty && workspace.translatedText.isEmpty)
        }
    }
}
