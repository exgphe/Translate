import Foundation
import Observation
import SwiftData

/// Composition root. One instance per app; windows and commands share it.
@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    let registry: EngineRegistry
    let workspace: TranslationWorkspace
    let container: ModelContainer
    let liveCaptions: LiveCaptionsController

    init() {
        let settings = AppSettings()
        let registry = EngineRegistry(settings: settings)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: HistoryEntry.self)
        } catch {
            // A corrupt store must not block translating; fall back to memory and keep going.
            container = try! ModelContainer(for: HistoryEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        self.settings = settings
        self.registry = registry
        self.container = container
        self.workspace = TranslationWorkspace(settings: settings, registry: registry, modelContext: container.mainContext)
        self.liveCaptions = LiveCaptionsController(settings: settings, registry: registry)
    }

    func deleteAllHistory() {
        try? container.mainContext.delete(model: HistoryEntry.self)
        try? container.mainContext.save()
    }
}
