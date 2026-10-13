import Foundation

/// Rouvrir l'app (Dock, Finder, `open`) sans fenêtre visible doit montrer la fenêtre principale : SwiftUI ne le fait pas
/// seul pour une scène `Window`. Une vue toujours présente (l'icône de la barre de menus) enregistre comment l'ouvrir.
@MainActor
public final class WindowReopener {
    public static let shared = WindowReopener()
    private var open: (() -> Void)?

    public init() {}

    public func register(_ open: @escaping () -> Void) {
        self.open = open
    }

    /// Vrai si la fenêtre a été rouverte.
    @discardableResult
    public func handleReopen(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let open else { return false }
        open()
        return true
    }
}
