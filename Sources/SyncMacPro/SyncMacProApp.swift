import AppKit
import SwiftUI
import SyncKit
import SyncMacProUI

/// Fermer la dernière fenêtre ne quitte pas l'app : elle reste dans la barre de menus. Quitter n'arrête pas l'agent.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SyncMacProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AgentModel
    @State private var installer = AgentInstaller()
    @State private var loginItem = LoginItemModel()
    @State private var updates = UpdateModel(checker: UpdateChecker(current: AppInfo.version()))
    @AppStorage("appearance") private var appearance = Appearance.auto.rawValue

    private let localizer = Localizer.system

    init() {
        let model = AgentModel(agent: AgentClient.machService(AgentIdentifiers.service()))
        _model = State(initialValue: model)
        // Le modèle démarre avec l'app, pas avec la fenêtre : l'icône de la barre de menus reste vivante même si
        // macOS relance l'app sans ouvrir sa fenêtre (restauration, ouverture à la connexion).
        model.start()
    }

    var body: some Scene {
        Window(localizer.text("app.name"), id: "main") {
            RootView(model: model, installer: installer, loginItem: loginItem, localizer: localizer, updates: updates)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .task { await updates.checkIfDue() }
        }
        .defaultSize(width: 1180, height: 720)

        MenuBarExtra {
            MenuBarContent(model: model, localizer: localizer)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        } label: {
            MenuBarIcon(model: model, localizer: localizer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(installer: installer, loginItem: loginItem, localizer: localizer)
                .frame(width: 520, height: 520)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
    }
}

/// L'icône reflète l'état en direct, même fenêtre fermée.
@MainActor
private struct MenuBarIcon: View {
    let model: AgentModel
    let localizer: Localizer

    var body: some View {
        MenuBarLabel(
            state: MenuBarState.make(connection: model.connection, status: model.status, progress: model.progress),
            localizer: localizer
        )
    }
}

@MainActor
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AgentModel
    let localizer: Localizer

    var body: some View {
        MenuBarPanel(
            model: model, text: CardText(localizer: localizer),
            onOpen: {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
