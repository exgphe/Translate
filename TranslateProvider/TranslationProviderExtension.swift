import ExtensionKit
import SwiftUI
import TranslationUIProvider

@main
final class TranslationProviderExtension: TranslationUIProviderExtension {
    required init() {}

    var body: some TranslationUIProviderExtensionScene {
        TranslationUIProviderSelectedTextScene { context in
            SelectedTextTranslationView(context: context)
        }
    }
}
