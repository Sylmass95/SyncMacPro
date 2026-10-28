import AppKit
import SwiftUI

/// Fenêtre flottante du mode miniature : au premier plan, sur tous les bureaux, position retenue (comme RsyncGUI).
/// Pendant le mode miniature, la grande fenêtre est masquée ; « Agrandir » la rouvre.
@MainActor
public final class MiniPanelController: NSObject, NSWindowDelegate {
    public static let shared = MiniPanelController()
    private var panel: NSPanel?
    /// Rouvre la grande fenêtre (remplaçable par les tests).
    var onRestore: () -> Void = { MiniPanelController.restoreMainWindow() }

    public var isShown: Bool { panel?.isVisible == true }

    public func toggle(model: AgentModel, localizer: Localizer) {
        if isShown { hide() } else { show(model: model, localizer: localizer) }
    }

    public func show(model: AgentModel, localizer: Localizer) {
        let panel = self.panel ?? makePanel(model: model, localizer: localizer)
        self.panel = panel
        for window in NSApp.windows where Self.isMainWindow(window) { window.orderOut(nil) }
        panel.orderFrontRegardless()
    }

    /// Ferme la miniature et rouvre la grande fenêtre.
    public func hide() {
        panel?.orderOut(nil)
        onRestore()
    }

    /// Fermer la miniature par sa croix rouvre aussi la grande fenêtre.
    public func windowWillClose(_ notification: Notification) { onRestore() }

    static func restoreMainWindow() {
        if let main = NSApp.windows.first(where: isMainWindow) {
            main.makeKeyAndOrderFront(nil)
        } else {
            WindowReopener.shared.handleReopen(hasVisibleWindows: false)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// La fenêtre de la scène `Window(id: "main")` (SwiftUI lui donne un identifiant qui commence par « main »).
    public static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    private func makePanel(model: AgentModel, localizer: Localizer) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = localizer.text("mini.title")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 340, height: 160)
        panel.delegate = self
        let controller = self
        panel.contentView = NSHostingView(rootView: MiniView(model: model, localizer: localizer) { controller.hide() }.glassThemed())
        panel.setFrameAutosaveName("SyncMacProMini")
        if !panel.setFrameUsingName("SyncMacProMini"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 400, y: screen.maxY - 320))
        }
        return panel
    }
}
