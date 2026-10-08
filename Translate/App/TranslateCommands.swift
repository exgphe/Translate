import SwiftUI

/// Menu bar commands. Every main action is reachable from the keyboard.
struct TranslateCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Translate") {
            Button("Translate") { model.workspace.translate() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.workspace.canTranslate)

            Button("Stop") { model.workspace.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.workspace.phase.isRunning && !model.workspace.explanationPhase.isRunning)

            Button("Retry") { model.workspace.retry() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.workspace.lastRequest == nil || model.workspace.phase.isRunning)

            Divider()

            Button("Paste and Translate") { model.workspace.pasteAndTranslate() }
                .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Import Image…") { model.workspace.isImportingImage = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Copy Translation") { model.workspace.copyTranslation() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.workspace.translatedText.isEmpty)

            Divider()

            Button("Swap Languages") { model.workspace.swapLanguages() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!model.workspace.canSwapLanguages)

            Button("Add Context…") { model.workspace.isShowingContext = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Button("Explain…") { model.workspace.isShowingExplain = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.workspace.translatedText.isEmpty)

            Divider()

            Button("Clear") { model.workspace.clear() }
                .keyboardShortcut("k", modifiers: .command)

            #if os(macOS)
            Divider()

            Button("Live Captions…") { openWindow(id: "live-captions") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            #endif
        }
    }
}
