import AppKit
import SwiftUI
import SyncKit
import SyncMacProUI

/// Fermer la dernière fenêtre ne quitte pas l'app : elle reste dans la barre de menus. Quitter n'arrête pas l'agent.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock, Finder, `open` : sans fenêtre visible, on rouvre la fenêtre principale.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowReopener.shared.handleReopen(hasVisibleWindows: flag)
        return true
    }
}

@main
struct SyncMacProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AgentModel
    @State private var installer: AgentInstaller
    @State private var loginItem = LoginItemModel()
    @State private var updates: UpdateModel
    @AppStorage("appearance") private var appearance = Appearance.auto.rawValue

    private let localizer = Localizer.system

    init() {
        // Lancée, l'app est autorisée : on retire la quarantaine de son bundle, sinon rsync, rclone et l'agent restent
        // bloqués (ils ne sont pas couverts par l'autorisation donnée à l'app).
        if Bundle.main.bundlePath.hasSuffix(".app"), InstallLocation.problem(bundlePath: Bundle.main.bundlePath) == nil {
            Quarantine.clear(bundle: Bundle.main.bundleURL)
        }
        let model = AgentModel(agent: AgentClient.machService(AgentIdentifiers.service()))
        _model = State(initialValue: model)
        // Le modèle démarre avec l'app, pas avec la fenêtre : l'icône de la barre de menus reste vivante même si
        // macOS relance l'app sans ouvrir sa fenêtre (restauration, ouverture à la connexion).
        model.start()
        // App mise à jour : l'agent enregistré par l'ancienne version ne démarrerait plus, on le réenregistre — quand
        // il est au repos, pour ne jamais couper une copie.
        let installer = AgentInstaller()
        if Bundle.main.bundlePath.hasSuffix(".app") {
            Task {
                await installer.reRegisterAfterUpdate(
                    // L'agent à redémarrer est périmé : seules ses copies en cours le retardent (1.6.7).
                    isIdle: { UpdatePolicy.agentCanRestart(connection: model.connection, status: model.status) ?? false },
                    // Autorisations de dossiers de l'ancienne version effacées, puis redemandées par l'agent mis à jour.
                    beforeReRegistering: { PermissionReset.resetAll(bundleID: Bundle.main.bundleIdentifier ?? "com.sylvain.syncmacpro") },
                    afterReRegistering: { await model.checkAccess() }
                )
            }
        }
        _installer = State(initialValue: installer)
        // Mises à jour (Sparkle, app installée seulement) : installées quand l'agent est au repos.
        let updates = UpdateModel(driver: SparkleUpdateDriver.makeIfBundled(), isIdle: {
            UpdatePolicy.agentIdleness(connection: model.connection, status: model.status)
        })
        _updates = State(initialValue: updates)
        updates.start()
        Task { @MainActor in
            while true {
                if let idle = UpdatePolicy.agentIdleness(connection: model.connection, status: model.status) {
                    updates.agentActivity(idle: idle)
                }
                // Programme de l'agent remplacé (1.6.7) : redémarré dès que ses copies sont finies, quelle que soit la
                // version enregistrée.
                if Bundle.main.bundlePath.hasSuffix(".app"), model.status?.restartPending == true,
                   UpdatePolicy.agentCanRestart(connection: model.connection, status: model.status) == true {
                    await installer.restartReplacedAgent(
                        beforeReRegistering: { PermissionReset.resetAll(bundleID: Bundle.main.bundleIdentifier ?? "com.sylvain.syncmacpro") },
                        afterReRegistering: { await model.checkAccess() }
                    )
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        if Bundle.main.bundlePath.hasSuffix(".app"), let version = UpdateModel.launchAnnouncement(current: AppInfo.version()) {
            let text = Localizer.system
            UserNotifier().notify(title: text.text("update.done.title"), body: text.format("update.done.body", version))
        }
    }

    var body: some Scene {
        Window(localizer.text("app.name"), id: "main") {
            RootView(model: model, installer: installer, loginItem: loginItem, localizer: localizer, updates: updates)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(after: .windowList) {
                Button(localizer.text("mini.toggle")) { MiniPanelController.shared.toggle(model: model, localizer: localizer) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model, localizer: localizer)
                .glassThemed()
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        } label: {
            MenuBarIcon(model: model, localizer: localizer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(installer: installer, loginItem: loginItem, localizer: localizer, updates: updates, model: model)
                .frame(width: 520, height: 520)
                .background(GlassBackdrop())
                .glassThemed()
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
    }
}

/// L'icône reflète l'état en direct, même fenêtre fermée.
@MainActor
private struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow
    let model: AgentModel
    let localizer: Localizer

    var body: some View {
        MenuBarLabel(
            state: MenuBarState.make(connection: model.connection, status: model.status, progress: model.progress),
            localizer: localizer
        )
        // L'icône est toujours là : c'est elle qui sait rouvrir la fenêtre quand on relance l'app.
        .onAppear {
            let open = openWindow
            WindowReopener.shared.register {
                open(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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
