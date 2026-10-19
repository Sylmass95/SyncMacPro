import AppKit
import SwiftUI
import SyncKit

/// Le tableau de bord sans son défilement : `ImageRenderer` ne dessine pas un `ScrollView`, les tests rendent ce contenu.
@MainActor
struct DashboardContent: View {
    let model: AgentModel
    let installState: AgentInstallState
    let text: CardText
    let onInstall: () -> Void
    var onCreate: (TaskDraft) -> Void = { _ in }
    var onEdit: (SyncTask) -> Void = { _ in }
    var update: UpdateBannerInfo?

    // 1.7.0 : la liste défile elle-même (une `List` dans un `ScrollView` s'écrase).
    var body: some View {
        DashboardBody(model: model, installState: installState, text: text, onInstall: onInstall, onCreate: onCreate, onEdit: onEdit,
                      update: update)
    }
}

@MainActor
struct DashboardBody: View {
    let model: AgentModel
    let installState: AgentInstallState
    let text: CardText
    let onInstall: () -> Void
    var onCreate: (TaskDraft) -> Void = { _ in }
    /// « Modifier… » du détail : éditeur complet (1.7.0).
    var onEdit: (SyncTask) -> Void = { _ in }
    /// Une mise à jour est prête (installation à la demande, ou en attente de la fin des copies).
    var update: UpdateBannerInfo?
    /// Lignes sélectionnées dans la liste (1.7.0).
    @State var selection: Set<UUID> = []

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ConnectionBanner(
                connection: model.connection, installState: installState, localizer: l,
                onRetry: { model.restart() }, onInstall: onInstall
            )
            if let update {
                Banner(systemImage: "arrow.down.circle", tint: .blue, title: UpdateText(localizer: l).banner(update)) {
                    if let install = update.install { Button(l.text("update.install"), action: install) }
                }
            }
            if model.status?.stateRecovered == true {
                Banner(systemImage: "exclamationmark.triangle", tint: .orange, title: l.text("banner.recovered")) {
                    Button(l.text("dashboard.resume")) { Task { await model.setGlobalPause(false) } }
                }
            }
            if let error = model.status?.taskLoadError {
                Banner(
                    systemImage: "exclamationmark.triangle", tint: .orange,
                    title: l.format("banner.tasksfile", error)
                ) {}
            }
            content
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(l.text("dashboard.title")).font(.largeTitle.bold())
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                pauseButton
                if model.status?.globalPause == true {
                    Text(l.text("dashboard.pause.on")).font(.caption.bold()).foregroundStyle(.orange)
                }
                Text(l.text("dashboard.pause.help"))
                    .font(.caption).foregroundStyle(.primary.opacity(0.7)).multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    @ViewBuilder private var pauseButton: some View {
        let paused = model.status?.globalPause == true
        Button {
            Task { await model.setGlobalPause(!paused) }
        } label: {
            Label(
                paused ? l.text("dashboard.resume") : l.text("dashboard.pause.global"),
                systemImage: paused ? "play.fill" : "pause.fill"
            )
        }
        .buttonStyle(GlassButtonStyle(prominent: true, color: paused ? .green : .accentColor))
        .disabled(model.globalPauseBusy || model.connection != .connected)
    }

    @ViewBuilder private var content: some View {
        if let status = model.status {
            if status.tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(l.text("dashboard.empty.title")).font(.title3.bold())
                    Text(l.text("dashboard.empty.body")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button { onCreate(TaskDraft()) } label: {
                            Label(l.text("dashboard.create"), systemImage: "plus")
                        }
                        .buttonStyle(GlassButtonStyle(prominent: true))
                        .disabled(model.connection != .connected)
                        TemplatesMenu(localizer: l) { onCreate(.template($0)) }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // 1.7.0 : une seule liste ordonnée, le détail de la tâche sélectionnée en dessous.
                VSplitView {
                    TaskListView(model: model, selection: $selection, text: text)
                        .frame(minHeight: 220)
                    detail.frame(minHeight: 160)
                }
            }
        }
    }

    /// Détail de la sélection, sous la liste.
    @ViewBuilder private var detail: some View {
        TaskDetailView(model: model, selection: selection, text: text, onEdit: onEdit)
    }

}

@MainActor
public struct DashboardView: View {
    let model: AgentModel
    let installer: AgentInstaller
    let localizer: Localizer
    let onCreate: (TaskDraft) -> Void
    let onEdit: (SyncTask) -> Void
    let updates: UpdateModel?

    public init(
        model: AgentModel, installer: AgentInstaller, localizer: Localizer = .system, updates: UpdateModel? = nil,
        onCreate: @escaping (TaskDraft) -> Void = { _ in }, onEdit: @escaping (SyncTask) -> Void = { _ in }
    ) {
        self.model = model
        self.installer = installer
        self.localizer = localizer
        self.updates = updates
        self.onCreate = onCreate
        self.onEdit = onEdit
    }

    public var body: some View {
        // Les « il y a 2 h » et « demain à 03:00 » se recalculent toutes les 30 s.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            DashboardContent(
                model: model, installState: installer.state,
                text: CardText(localizer: localizer, now: context.date),
                onInstall: { installer.install(); model.restart() },
                onCreate: onCreate, onEdit: onEdit,
                update: updates.flatMap(UpdateBannerInfo.make)
            )
        }
    }
}

/// Bannière de mise à jour : prête et à installer à la demande (bouton), ou prête et en attente de la fin des copies.
struct UpdateBannerInfo {
    let version: String
    let waitingForCopies: Bool
    /// Prête hors de la plage horaire d'installation (1.6.4).
    var waitingForDaytime = false
    var hours: Range<Int> = 9..<19
    let install: (() -> Void)?

    @MainActor
    static func make(_ updates: UpdateModel) -> UpdateBannerInfo? {
        guard let version = updates.readyVersion else { return nil }
        if updates.waitingForDaytime {
            return UpdateBannerInfo(version: version, waitingForCopies: false, waitingForDaytime: true,
                                    hours: updates.installFrom..<max(updates.installFrom + 1, updates.installUntil), install: nil)
        }
        if updates.waitingForCopies { return UpdateBannerInfo(version: version, waitingForCopies: true, install: nil) }
        if updates.autoInstall { return nil }   // elle s'installe d'elle-même
        return UpdateBannerInfo(version: version, waitingForCopies: false, install: { updates.installNow() })
    }
}
