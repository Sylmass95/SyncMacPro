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
    @State private var model = AgentModel(agent: AgentClient.machService())
    @State private var installer = AgentInstaller()
    @State private var loginItem = LoginItemModel()
    @AppStorage("appearance") private var appearance = Appearance.auto.rawValue

    private let localizer = Localizer.system

    var body: some Scene {
        Window(localizer.text("app.name"), id: "main") {
            RootView(model: model, installer: installer, loginItem: loginItem, localizer: localizer)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .task { model.start() }
        }

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
