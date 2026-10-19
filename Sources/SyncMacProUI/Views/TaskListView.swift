import SwiftUI
import SyncKit

/// Une ligne de la liste (1.7.0) : rang, nom, de → vers, horaire, état (progression, raison de l'attente), dernière
/// exécution, boutons.
@MainActor
struct TaskRow: View {
    let info: AgentTaskInfo
    let task: SyncTask?
    let progress: ProgressInfo?
    let busy: Bool
    let text: CardText
    let actions: TaskCardActions

    private var l: Localizer { text.localizer }
    private var row: RowText { RowText(localizer: l) }

    static func opacity(for info: AgentTaskInfo) -> Double { info.state == .disabled ? 0.5 : 1 }

    /// Largeurs (revue 1.7.0) : les colonnes se resserrent ; la ligne tient dans la liste à la taille minimale de la
    /// fenêtre (environ 680 pt une fois la barre latérale et les marges ôtées).
    enum Column {
        static let rank: CGFloat = 24, name: CGFloat = 170, schedule: CGFloat = 110, state: CGFloat = 160
        static let last: CGFloat = 90, buttons: CGFloat = 84, spacing: CGFloat = 8
    }
    static var minimumWidth: CGFloat {
        Column.rank + Column.name + Column.schedule + Column.state + Column.last + Column.buttons + 5 * Column.spacing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Column.spacing) {
            Text(row.rank(info)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: Column.rank, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    ForEach(row.badges(info), id: \.self) { badge in
                        Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                if let task { Text(row.route(task)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(minWidth: Column.name, maxWidth: .infinity, alignment: .leading)
            Text(task.map { $0.removableDrive != nil ? l.text("card.schedule.drive") : text.schedule($0.schedule) } ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(minWidth: Column.schedule, maxWidth: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.state(info, text: text)).font(.caption).lineLimit(2)
                if let progress, info.state == .running || info.state == .paused {
                    GlowProgressBar(value: Self.fraction(progress)).frame(height: 6)
                }
            }
            .frame(minWidth: Column.state, maxWidth: 240, alignment: .leading)
            Text(text.lastRun(info.lastRun)).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(minWidth: Column.last, maxWidth: 130, alignment: .leading)
            HStack(spacing: 2) { buttons }.buttonStyle(.borderless).controlSize(.small).frame(width: Column.buttons, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(Self.opacity(for: info))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.rank(info)). \(info.name), \(row.state(info, text: text))")
    }

    static func fraction(_ info: ProgressInfo) -> Double {
        if let percent = info.overallPercent { return min(1, max(0, Double(percent) / 100)) }
        guard let total = info.totalBytes, total > 0 else { return 0 }
        return min(1, Double(info.doneBytes) / Double(total))
    }

    @ViewBuilder private var buttons: some View {
        ForEach(TaskCard.availableActions(info: info, task: task, driveMounted: info.driveMounted), id: \.self) { action in
            switch action {
            case .run: icon("card.run", "play.fill", actions.run)
            case .force: icon("card.force", "forward.fill", actions.force)
            case .pause: icon("card.pause", "pause.fill", actions.pause)
            case .resume: icon("card.resume", "play.fill", actions.resume)
            case .stop: icon("card.stop", "stop.fill", actions.stop)
            case .approve: icon("card.approve", "checkmark.shield", actions.approve)
            case .abandon: icon("card.abandon", "xmark.circle", actions.abandon)
            case .eject: icon("card.eject", "eject.fill", actions.eject)
            }
        }
    }

    private func icon(_ key: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(l.text(key)).accessibilityLabel(l.text(key)).disabled(busy)
    }
}

/// La liste ordonnée (1.7.0) : glisser-déposer (une ou plusieurs lignes), sélection multiple, actions groupées, et une
/// dernière ligne fixe « Autres exécutions » (copies ponctuelles terminées, tâches supprimées).
@MainActor
struct TaskListView: View {
    let model: AgentModel
    @Binding var selection: Set<UUID>
    let text: CardText

    /// Identifiant réservé de la ligne « Autres exécutions ».
    static let otherRunsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    static func rowIDs(_ infos: [AgentTaskInfo]) -> [UUID] { infos.map(\.id) + [otherRunsID] }

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(spacing: 0) {
            selectionBar
            List(selection: $selection) {
                ForEach(model.orderedTasks) { info in
                    TaskRow(info: info, task: model.tasks[info.id], progress: model.progress[info.id],
                            busy: model.busyTasks.contains(info.id), text: text, actions: actions(for: info.id))
                        .tag(info.id)
                }
                .onMove { indices, offset in
                    let ids = Set(indices.map { model.orderedTasks[$0].id })
                    Task { await model.move(ids, toOffset: offset) }
                }
                Label(l.text("list.otherRuns"), systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary).tag(Self.otherRunsID).moveDisabled(true)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in groupActions(ids) }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        let ids = selection.subtracting([Self.otherRunsID])
        HStack(spacing: 8) {
            Text(ids.count > 1 ? l.format("list.selection.count", ids.count) : " ").font(.caption).foregroundStyle(.secondary)
            Spacer()
            groupActions(ids)
        }
        .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
        .disabled(ids.isEmpty || model.connection != .connected)
    }

    @ViewBuilder private func groupActions(_ chosen: Set<UUID>) -> some View {
        let ids = chosen.subtracting([Self.otherRunsID])
        Button { each(ids) { await model.runNow($0) } } label: { Label(l.text("card.run"), systemImage: "play.fill") }
        Button { each(ids) { await model.force($0) } } label: { Label(l.text("card.force"), systemImage: "forward.fill") }
        Button { each(ids) { await model.pause($0) } } label: { Label(l.text("card.pause"), systemImage: "pause.fill") }
        Button { each(ids) { await model.setEnabled($0, true) } } label: { Label(l.text("list.enable"), systemImage: "checkmark.circle") }
        Button { each(ids) { await model.setEnabled($0, false) } } label: { Label(l.text("list.disable"), systemImage: "minus.circle") }
    }

    private func each(_ ids: Set<UUID>, _ body: @escaping @MainActor (UUID) async -> Void) {
        let ordered = model.orderedTasks.map(\.id).filter { ids.contains($0) }
        Task { for id in ordered { await body(id) } }
    }

    private func actions(for id: UUID) -> TaskCardActions {
        TaskCardActions(
            run: { Task { await model.runNow(id) } },
            force: { Task { await model.force(id) } },
            pause: { Task { await model.pause(id) } },
            resume: { Task { await model.resume(id) } },
            stop: { Task { await model.stop(id) } },
            approve: { Task { await model.approve(id) } },
            abandon: { Task { await model.abandonSuspended(id) } },
            eject: { Task { await model.ejectDrive(id) } }
        )
    }
}
