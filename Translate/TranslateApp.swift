//
//  TranslateApp.swift
//  Translate
//

import SwiftData
import SwiftUI

@main
struct TranslateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Translate") {
            ContentView()
                .environment(model)
                .environment(model.workspace)
                .environment(model.registry)
                .environment(model.settings)
                .task { await model.registry.refresh() }
        }
        .modelContainer(model.container)
        .defaultSize(width: 1000, height: 640)
        .commands {
            TranslateCommands(model: model)
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .environment(model.registry)
                .environment(model.settings)
        }
        .modelContainer(model.container)

        Window("Live Captions", id: "live-captions") {
            LiveCaptionsView()
                .environment(model.liveCaptions)
                .environment(model.registry)
                .frame(minWidth: 460, minHeight: 520)
        }
        .defaultSize(width: 520, height: 720)
        #endif

        #if os(visionOS)
        // Value-based so opening an already-open window brings it forward instead of duplicating it.
        WindowGroup("Live Captions", id: "live-captions", for: String.self) { _ in
            LiveCaptionsView()
                .environment(model.liveCaptions)
                .environment(model.registry)
        }
        .defaultSize(width: 640, height: 820)

        WindowGroup("Captions", id: "caption-overlay", for: String.self) { _ in
            CaptionOverlayView()
                .environment(model.liveCaptions)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1100, height: 260)
        #endif
    }
}
