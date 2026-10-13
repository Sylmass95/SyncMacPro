import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case dashboard, history, settings
    public var id: String { rawValue }
}

/// Fenêtre principale : barre latérale (tableau de bord, historique, réglages) et accueil au premier lancement.
@MainActor
public struct RootView: View {
    let model: AgentModel
    let installer: AgentInstaller
    let loginItem: LoginItemModel
    let localizer: Localizer
    @State private var selection: SidebarItem? = .dashboard

    public init(model: AgentModel, installer: AgentInstaller, loginItem: LoginItemModel, localizer: Localizer = .system) {
        self.model = model
        self.installer = installer
        self.loginItem = loginItem
        self.localizer = localizer
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
        }
        .frame(minWidth: 860, minHeight: 560)
        // L'agent a disparu (désinstallé, désactivé) : on relit son état pour proposer la bonne action.
        .onChange(of: model.connection) { _, state in
            if state == .unreachable { installer.refresh() }
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
    }

    @ViewBuilder private var detail: some View {
        if Self.shouldShowOnboarding(connection: model.connection, installState: installer.state) {
            OnboardingView(installer: installer, localizer: localizer) {
                installer.install()
                model.restart()
            }
        } else {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView(model: model, installer: installer, localizer: localizer)
            case .history: HistoryView(model: model, localizer: localizer)
            case .settings: SettingsView(installer: installer, loginItem: loginItem, localizer: localizer)
            }
        }
    }

    private func title(_ item: SidebarItem) -> String {
        switch item {
        case .dashboard: return localizer.text("sidebar.dashboard")
        case .history: return localizer.text("sidebar.history")
        case .settings: return localizer.text("sidebar.settings")
        }
    }

    private func icon(_ item: SidebarItem) -> String {
        switch item {
        case .dashboard: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}
