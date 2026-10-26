import SwiftUI
import SyncKit

/// Icône de la barre de menus : symbole selon l'état, et « 42 % » ou « 2 copies » pendant une copie.
@MainActor
public struct MenuBarLabel: View {
    let state: MenuBarState
    let localizer: Localizer

    public init(state: MenuBarState, localizer: Localizer = .system) {
        self.state = state
        self.localizer = localizer
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.systemImage)
            if let title = state.title(localizer) { Text(title).monospacedDigit() }
        }
    }
}

/// Panneau de la barre de menus : copies actives, prochaines exécutions, pause globale, ouvrir, quitter.
@MainActor
public struct MenuBarPanel: View {
    let model: AgentModel
    let text: CardText
    let onOpen: () -> Void
    let onQuit: () -> Void

    public init(model: AgentModel, text: CardText, onOpen: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.text = text
        self.onOpen = onOpen
        self.onQuit = onQuit
    }

    private var l: Localizer { text.localizer }
    private var tasks: [AgentTaskInfo] { model.status?.tasks ?? [] }
    private var active: [AgentTaskInfo] { tasks.filter { $0.state == .running || $0.state == .paused } }
    private var upcoming: [AgentTaskInfo] {
        Self.upcoming(tasks, isManual: { model.tasks[$0]?.schedule == .manual })
    }

    /// « À venir » (1.7.0) : les tâches en attente et les tâches programmées, dans l'ordre de la liste, trois au plus.
    /// Une tâche manuelle n'a pas d'échéance à annoncer.
    static func upcoming(_ infos: [AgentTaskInfo], isManual: (UUID) -> Bool) -> [AgentTaskInfo] {
        let next = infos.filter { info in
            info.state == .queued || (info.nextDue != nil && info.state != .disabled && !isManual(info.id))
        }
        return Array(next.prefix(3))
    }

    /// Vrai état (1.7.6) : « Préparation… » plutôt que « En cours » pendant la comparaison préalable.
    static func stateLine(_ info: AgentTaskInfo, text: CardText) -> String { RowText(localizer: text.localizer).state(info, text: text) }

    // 1.7.6 : une carte par rubrique, chaque tâche sur ses lignes (nom, puis état dessous), séparées d'un trait gris.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.connection != .connected {
                ConnectionBanner(
                    connection: model.connection, installState: .unknown, localizer: l,
                    onRetry: { model.restart() }, onInstall: {}
                )
            }
            card(l.text("menubar.active")) {
                if active.isEmpty {
                    Text(l.text("menubar.none")).foregroundStyle(.secondary).font(.callout)
                } else {
                    separated(active) { activeRow($0) }
                }
            }
            let drives = DrivePresentation.attentionIDs(status: model.status, tasks: model.tasks)
            if !drives.isEmpty {
                card(l.text("menubar.drives")) {
                    separated(tasks.filter { drives.contains($0.id) }) { driveRow($0) }
                }
            }
            card(l.text("menubar.upcoming")) {
                if upcoming.isEmpty {
                    Text(l.text("menubar.nonext")).foregroundStyle(.secondary).font(.callout)
                } else {
                    separated(upcoming) { info in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.name).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text(info.state == .queued ? l.text("menubar.next.queued") : text.nextRun(info.nextDue))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                pauseButton
                Spacer()
                Button(l.text("menubar.quit"), action: onQuit)
                Button(l.text("menubar.open"), action: onOpen).buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 340)
        // 1.8.7 : fond opaque ; transparent, on lisait mal à travers le panneau.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Orange seulement pour un vrai problème : disque débranché pendant une sauvegarde (1.8.7).
    static func driveNeedsAttention(_ info: AgentTaskInfo) -> Bool {
        info.driveSuspendedSince != nil || info.driveMounted == false
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .separatorColor)))
    }

    private func separated<Content: View>(_ infos: [AgentTaskInfo], @ViewBuilder row: @escaping (AgentTaskInfo) -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(infos.enumerated()), id: \.element.id) { index, info in
                if index > 0 { Divider().overlay(Color.gray.opacity(0.35)) }
                row(info)
            }
        }
    }

    private func activeRow(_ info: AgentTaskInfo) -> some View {
        let progress = model.progress[info.id]
        let busy = model.busyTasks.contains(info.id)
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(Self.stateLine(info, text: text)).font(.caption)
                    .foregroundStyle(info.state == .paused ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    GlowProgressBar(value: TaskRow.fraction(progress), height: 4).accessibilityLabel(info.name)
                    Text(text.progressLine(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 1.8.7 : le fichier en cours, en une ligne (nom et pourcentage).
                    if let file = TaskRow.currentFile(progress, text: text) {
                        Text("\((file.name as NSString).lastPathComponent) · \(Int((file.fraction * 100 + 1e-9).rounded(.down))) %")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file.name)
                    }
                }
            }
            Spacer(minLength: 4)
            if info.state == .running {
                iconButton("list.tip.pause", "pause.fill") { Task { await model.pause(info.id) } }.disabled(busy)
            } else if info.resumePending != true {
                iconButton("list.tip.resume", "play.fill") { Task { await model.resume(info.id) } }.disabled(busy)
            }
            iconButton("list.tip.stop", "stop.fill") { Task { await model.stop(info.id) } }.disabled(busy)
        }
    }

    private func iconButton(_ key: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 12, height: 12) }
            .buttonStyle(.bordered).help(l.text(key)).accessibilityLabel(l.text(key))
    }

    private func driveRow(_ info: AgentTaskInfo) -> some View {
        let task = model.tasks[info.id]
        let actions = TaskCard.availableActions(info: info, task: task, driveMounted: info.driveMounted)
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let line = DrivePresentation(localizer: l, now: text.now).line(info: info, task: task) {
                    Text(line).font(.caption)
                        .foregroundStyle(Self.driveNeedsAttention(info) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if actions.contains(.abandon) {
                iconButton("list.tip.abandon", "xmark.circle.fill") { Task { await model.abandonSuspended(info.id) } }
            }
            if actions.contains(.eject) {
                iconButton("list.tip.eject", "eject.fill") { Task { await model.ejectDrive(info.id) } }
            }
        }
        .disabled(model.busyTasks.contains(info.id))
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
        .disabled(model.globalPauseBusy || model.connection != .connected)
    }
}
