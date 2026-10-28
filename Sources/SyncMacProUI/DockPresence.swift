import AppKit

/// 1.8.9 : SyncMacPro n'est dans le Dock que tant qu'une de ses fenêtres est ouverte (principale, détails, réglages).
/// Fenêtres fermées ou réduites, il ne vit plus que dans la barre de menus. Réduire masque la fenêtre : sans icône dans
/// le Dock, une fenêtre réduite n'aurait nulle part où aller.
@MainActor
public final class DockPresence: NSObject {
    public static let shared = DockPresence()

    struct WindowInfo: Equatable {
        var isVisible: Bool
        var isTitled: Bool
        /// Panneau (miniature, barre de menus) : ne ramène pas l'icône.
        var isPanel: Bool
    }

    /// Fenêtres masquées par « Réduire » ou au lancement à la connexion : réaffichées telles quelles.
    private var hidden: [NSWindow] = []
    private var started = false

    static func policy(for windows: [WindowInfo]) -> NSApplication.ActivationPolicy {
        windows.contains { $0.isVisible && $0.isTitled && !$0.isPanel } ? .regular : .accessory
    }

    public func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        // Après chaque événement traité : une fenêtre ouverte, fermée ou masquée change la présence dans le Dock.
        center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockPresence.shared.refresh() }
        }
        // ⌘M ne passe pas par le bouton jaune : la fenêtre réduite est aussitôt masquée.
        center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                window.deminiaturize(nil)
                DockPresence.shared.hide(window)
            }
        }
    }

    /// Masque une fenêtre sans la fermer : elle sera réaffichée telle quelle.
    public func hide(_ window: NSWindow) {
        if !hidden.contains(where: { $0 === window }) { hidden.append(window) }
        window.orderOut(nil)
        refresh()
    }

    /// Montre la fenêtre principale : celle qui a été masquée, sinon une nouvelle (`open`).
    public func reveal(open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        if let window = hidden.first(where: { MiniPanelController.isMainWindow($0) }) {
            hidden.removeAll { $0 === window }
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        let windows = NSApp.windows
        for window in windows where Self.info(window).isTitled && !Self.info(window).isPanel { redirectMinimize(window) }
        hidden.removeAll { $0.isVisible }
        let policy = Self.policy(for: windows.map(Self.info))
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc private func minimize(_ sender: NSButton) {
        if let window = sender.window { hide(window) }
    }

    private func redirectMinimize(_ window: NSWindow) {
        guard let button = window.standardWindowButton(.miniaturizeButton), button.target !== self else { return }
        button.target = self
        button.action = #selector(minimize(_:))
    }

    private static func info(_ window: NSWindow) -> WindowInfo {
        WindowInfo(isVisible: window.isVisible && !window.isMiniaturized, isTitled: window.styleMask.contains(.titled),
                   isPanel: window is NSPanel)
    }
}

/// Comment l'app a été lancée. À l'ouverture de session, elle démarre dans la barre de menus, sans fenêtre.
@MainActor
public final class LaunchContext {
    public static var shared = LaunchContext(atLogin: false)
    public let atLogin: Bool
    private var firstWindowHandled = false

    public init(atLogin: Bool) {
        self.atLogin = atLogin
    }

    /// L'événement d'ouverture envoyé par macOS porte « lancée comme élément d'ouverture » à la connexion.
    public static func isLoginLaunch(event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Vrai une seule fois, pour la fenêtre que SwiftUI ouvre au lancement à la connexion.
    public func shouldHideFirstWindow() -> Bool {
        defer { firstWindowHandled = true }
        return atLogin && !firstWindowHandled
    }
}
