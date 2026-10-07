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
        #endif
    }
}
