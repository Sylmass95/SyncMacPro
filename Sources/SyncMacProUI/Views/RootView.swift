import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case dashboard, tasks, copy, history, connections, settings
    public var id: String { rawValue }
}

struct EditorSession: Identifiable {
    let id = UUID()
    let draft: TaskDraft
    let isNew: Bool
}

/// Fenêtre principale : barre latérale (tableau de bord, tâches, copie, historique, connexions, réglages) et accueil au premier lancement.
@MainActor
public struct RootView: View {
    let model: AgentModel
    let installer: AgentInstaller
    let loginItem: LoginItemModel
    let localizer: Localizer
    let updates: UpdateModel?
    @State private var selection: SidebarItem? = .dashboard
    @State private var editor: EditorSession?

    public init(
        model: AgentModel, installer: AgentInstaller, loginItem: LoginItemModel, localizer: Localizer = .system,
        updates: UpdateModel? = nil
    ) {
        self.model = model
        self.installer = installer
        self.loginItem = loginItem
        self.localizer = localizer
        self.updates = updates
    }

    /// L'accueil ne s'affiche que si l'agent est injoignable ET pas installé : un agent installé mais muet, ou un agent
    /// déjà connecté (développement), n'en a pas besoin.
    public static func shouldShowOnboarding(connection: ConnectionState, installState: AgentInstallState) -> Bool {
        connection == .unreachable && (installState == .notRegistered || installState == .notFound)
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(title(item), systemImage: icon(item)).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            detail
                .scrollContentBackground(.hidden)
                .background(GlassBackdrop())
        }
        .frame(minWidth: 940, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    MiniPanelController.shared.show(model: model, localizer: localizer)
                } label: {
                    Label(localizer.text("mini.toggle"), systemImage: "rectangle.inset.bottomright.filled")
                }
                .help(localizer.text("mini.toggle") + " (⌥⌘M)")
            }
        }
        .glassThemed()
        // L'agent a disparu (désinstallé, désactivé) : on relit son état pour proposer la bonne action.
        .onChange(of: model.connection) { _, state in
            guard state == .unreachable else { return }
            installer.refresh()
            // Déclaré installé mais muet (ancienne signature après une mise à jour…) : on le réenregistre une fois.
            if installer.state == .enabled && Bundle.main.bundlePath.hasSuffix(".app") {
                Task {
                    if await installer.repairIfStuck() { model.restart() }
                }
            }
        }
        .alert(
            localizer.text("alert.title"),
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            actions: { Button(localizer.text("alert.ok")) {} },
            message: { Text(model.alertMessage ?? "") }
        )
        .sheet(item: $editor) { session in
            TaskEditorView(model: model, draft: session.draft, isNew: session.isNew, localizer: localizer) {
                editor = nil
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if Self.shouldShowOnboarding(connection: model.connection, installState: installer.state) {
            OnboardingView(installer: installer, localizer: localizer, location: InstallLocation.problem(bundlePath: Bundle.main.bundlePath)) {
                installer.install()
                model.restart()
            }
        } else {
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView(model: model, installer: installer, localizer: localizer, updates: updates,
                              onCreate: { open($0, isNew: true) }, onEdit: { open(TaskDraft(task: $0), isNew: false) })
            case .tasks:
                TasksView(model: model, localizer: localizer) { open($0, isNew: $1) }
            case .copy:
                CopyView(model: model, localizer: localizer) { open($0, isNew: true) }
            case .history: HistoryView(model: model, localizer: localizer)
            case .connections: ConnectionsView(model: model, localizer: localizer)
            case .settings: SettingsView(installer: installer, loginItem: loginItem, localizer: localizer, updates: updates, model: model)
            }
        }
    }

    private func open(_ draft: TaskDraft, isNew: Bool) {
        editor = EditorSession(draft: draft, isNew: isNew)
    }

    private func title(_ item: SidebarItem) -> String {
        switch item {
        case .dashboard: return localizer.text("sidebar.dashboard")
        case .tasks: return localizer.text("sidebar.tasks")
        case .copy: return localizer.text("sidebar.copy")
        case .history: return localizer.text("sidebar.history")
        case .connections: return localizer.text("sidebar.connections")
        case .settings: return localizer.text("sidebar.settings")
        }
    }

    private func icon(_ item: SidebarItem) -> String {
        switch item {
        case .dashboard: return "square.grid.2x2"
        case .tasks: return "list.bullet.rectangle"
        case .copy: return "doc.on.doc"
        case .history: return "clock.arrow.circlepath"
        case .connections: return "link"
        case .settings: return "gearshape"
        }
    }
}
