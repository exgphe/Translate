import SwiftData
import SwiftUI
import TranslationCore

struct HistorySidebar: View {
    @Binding var selection: UUID?
    /// When set (compact layouts), tapping a row calls this instead of using list selection.
    var onPick: ((HistoryEntry) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Query(sort: \HistoryEntry.createdAt, order: .reverse) private var entries: [HistoryEntry]
    @State private var isConfirmingClear = false

    var body: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                Group {
                    if let onPick {
                        Button { onPick(entry) } label: { HistoryRow(entry: entry) }
                            .buttonStyle(.plain)
                    } else {
                        HistoryRow(entry: entry).tag(entry.id)
                    }
                }
                    .contextMenu {
                        Button("Copy Translation") { Pasteboard.copy(entry.translatedText) }
                        Button("Delete", role: .destructive) { delete(entry) }
                    }
            }
            .onDelete { offsets in
                offsets.map { entries[$0] }.forEach(delete)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("History")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No History", systemImage: "clock")
                } description: {
                    Text(settings.historyEnabled ? "Translations are kept on this device only." : "History is turned off in Settings.")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Clear History", systemImage: "trash") { isConfirmingClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("Delete all history?", isPresented: $isConfirmingClear) {
            Button("Delete All", role: .destructive) {
                selection = nil
                model.deleteAllHistory()
            }
        } message: {
            Text("This removes every saved translation from this device. This cannot be undone.")
        }
    }

    private func delete(_ entry: HistoryEntry) {
        if selection == entry.id { selection = nil }
        modelContext.delete(entry)
        try? modelContext.save()
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.translatedText.firstLine)
                .lineLimit(2)
            Text(entry.sourceText.firstLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(languagePair)
                Text("·")
                Text(entry.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var languagePair: String {
        let source = entry.sourceLanguageCode?.displayName() ?? "Auto"
        return "\(source) → \(entry.targetLanguageCode.displayName())"
    }
}

private extension String {
    var firstLine: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
    }
}
