#if os(iOS)
import SwiftUI
import UIKit

/// The system menu's standard Paste action authorizes clipboard access;
/// the surrounding toolbar supplies the same glass background as its other items.
struct ToolbarPasteButton: UIViewRepresentable {
    var isEnabled: Bool
    var onPaste: ([PastedContent]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste) }

    func makeUIView(context: Context) -> UIButton {
        let coordinator = context.coordinator
        let action = UIAction(title: String(localized: "Paste"), identifier: .paste) { [weak coordinator] _ in
            coordinator?.paste()
        }
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .label
        configuration.buttonSize = .large
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.configuration?.title = String(localized: "Paste")
        button.menu = UIMenu(children: [action])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "pasteButton"
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.onPaste = onPaste
        uiView.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: max(44, size.width), height: 44)
    }

    static func dismantleUIView(_ uiView: UIButton, coordinator: Coordinator) {
        coordinator.cancelPendingPaste()
    }

    @MainActor
    final class Coordinator {
        var onPaste: ([PastedContent]) -> Void
        private var progress: Progress?
        private var requestID = UUID()

        init(onPaste: @escaping ([PastedContent]) -> Void) { self.onPaste = onPaste }

        func paste() {
            cancelPendingPaste()
            // Read only inside the user-triggered standard Paste action.
            guard let provider = UIPasteboard.general.itemProviders.first(where: { provider in
                provider.canLoadObject(ofClass: NSString.self) || provider.canLoadObject(ofClass: UIImage.self)
            }) else { return }
            let requestID = requestID
            if provider.canLoadObject(ofClass: NSString.self) {
                progress = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                    let text = object as? String
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID else { return }
                        self.progress = nil
                        if let text { self.onPaste([.text(text)]) }
                    }
                }
            } else {
                progress = provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    let data = (object as? UIImage)?.pngData()
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID else { return }
                        self.progress = nil
                        if let data { self.onPaste([.image(data)]) }
                    }
                }
            }
        }

        func cancelPendingPaste() {
            requestID = UUID()
            progress?.cancel()
            progress = nil
        }
    }
}
#endif
