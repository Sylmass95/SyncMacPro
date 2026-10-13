import SwiftUI
import SyncKit

/// Le tableau de bord sans son défilement : `ImageRenderer` ne dessine pas un `ScrollView`, les tests rendent ce contenu.
struct DashboardContent: View {
    let model: AgentModel
    let installState: AgentInstallState
    let text: CardText
    let onInstall: () -> Void

    var body: some View {
        ScrollView {
            DashboardBody(model: model, installState: installState, text: text, onInstall: onInstall)
        }
    }
}

struct DashboardBody: View {
    let model: AgentModel
    let installState: AgentInstallState
    let text: CardText
    let onInstall: () -> Void

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ConnectionBanner(
                connection: model.connection, installState: installState, localizer: l,
                onRetry: { model.restart() }, onInstall: onInstall
            )
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
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
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
        .buttonStyle(.borderedProminent)
        .tint(paused ? .green : .accentColor)
        .disabled(model.globalPauseBusy || model.connection != .connected)
    }

    @ViewBuilder private var content: some View {
        if let status = model.status {
            if status.tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(l.text("dashboard.empty.title")).font(.title3.bold())
                    Text(l.text("dashboard.empty.body")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(CardOrdering.sorted(status.tasks)) { info in
                        TaskCard(
                            info: info, task: model.tasks[info.id], progress: model.progress[info.id],
                            busy: model.busyTasks.contains(info.id), text: text, actions: actions(for: info.id)
                        )
                    }
                }
            }
        }
    }

    private func actions(for id: UUID) -> TaskCardActions {
        TaskCardActions(
            run: { Task { await model.runNow(id) } },
            pause: { Task { await model.pause(id) } },
            resume: { Task { await model.resume(id) } },
            stop: { Task { await model.stop(id) } },
            approve: { Task { await model.approve(id) } }
        )
    }
}

public struct DashboardView: View {
    let model: AgentModel
    let installer: AgentInstaller
    let localizer: Localizer

    public init(model: AgentModel, installer: AgentInstaller, localizer: Localizer = .system) {
        self.model = model
        self.installer = installer
        self.localizer = localizer
    }

    public var body: some View {
        // Les « il y a 2 h » et « demain à 03:00 » se recalculent toutes les 30 s.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            DashboardContent(
                model: model, installState: installer.state,
                text: CardText(localizer: localizer, now: context.date),
                onInstall: { installer.install(); model.restart() }
            )
        }
    }
}
