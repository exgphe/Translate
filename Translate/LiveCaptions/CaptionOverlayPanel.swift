#if os(macOS)
import AppKit
import SwiftUI

/// A borderless, transparent, click-through panel near the bottom of the screen. It floats over
/// every Space, including full-screen video, and never takes focus from the video app.
@MainActor
final class CaptionOverlayPanelController {
    private var panel: NSPanel?

    func show(controller: LiveCaptionsController) {
        let panel = self.panel ?? makePanel(controller: controller)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// While adjusting, the panel takes the mouse so it can be dragged; otherwise clicks pass
    /// through to the video underneath.
    func setAdjusting(_ adjusting: Bool, controller: LiveCaptionsController) {
        if adjusting { show(controller: controller) }
        panel?.ignoresMouseEvents = !adjusting
        panel?.isMovableByWindowBackground = adjusting
        if !adjusting, controller.phase != .running { hide() }
    }

    private func makePanel(controller: LiveCaptionsController) -> NSPanel {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(visible.width * 0.8, 1100)
        let height: CGFloat = 240
        let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 32, width: width, height: height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("LiveCaptionOverlay")

        let hosting = NSHostingView(rootView: CaptionOverlayView().environment(controller))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}
#endif
