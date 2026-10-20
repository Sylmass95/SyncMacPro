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

    /// Largeurs choisies dans l'en-tête de la liste (1.7.5).
    var columns = ListColumns()

    /// La ligne tient dans la liste à la taille minimale de la fenêtre (environ 680 pt), colonnes au plus étroit.
    static var minimumWidth: CGFloat {
        ListColumn.allCases.reduce(0) { $0 + $1.minimum } + CGFloat(ListColumn.allCases.count - 1) * ListColumns.spacing
    }

    var body: some View {
        // 1.7.5 : rien n'est coupé — les textes passent à la ligne au lieu d'être tronqués.
        HStack(alignment: .top, spacing: ListColumns.spacing) {
            Text(row.rank(info)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: columns.width(.rank), alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(info.name).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(row.badges(info), id: \.self) { badge in
                        Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                if let task {
                    Text(row.route(task)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: ListColumn.task.minimum, maxWidth: .infinity, alignment: .leading)
            Text(task.map { $0.removableDrive != nil ? l.text("card.schedule.drive") : text.schedule($0.schedule) } ?? "")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(width: columns.width(.schedule), alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.state(info, text: text)).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let progress, info.state == .running || info.state == .paused {
                    GlowProgressBar(value: Self.fraction(progress)).frame(height: 6)
                    ForEach(Array(Self.progressLines(progress, text: text).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout.monospacedDigit()).foregroundStyle(.primary.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            .frame(width: columns.width(.state), alignment: .leading)
            Text(text.lastRun(info.lastRun)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(width: columns.width(.last), alignment: .leading)
            HStack(spacing: 2) { buttons }.buttonStyle(.borderless).controlSize(.small)
                .frame(width: columns.width(.actions), alignment: .trailing)
        }
        .padding(.vertical, 5)
        .opacity(Self.opacity(for: info))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.rank(info)). \(info.name), \(row.state(info, text: text))")
    }

    /// Trois lignes complètes (1.7.5) : « 33 % · 1,00 Go sur 3,00 Go », « 45,0 Mo/s · reste 0:12 », puis le fichier
    /// en cours (chemin entier).
    static func progressLines(_ progress: ProgressInfo, text: CardText) -> [String] {
        let l = text.localizer
        let done = l.bytes(progress.doneBytes)
        var lines: [String] = []
        if let total = progress.totalBytes, total > 0 {
            let volume = l.format("progress.volume", done, l.bytes(total))
            lines.append(progress.overallPercent.map { "\($0) % · \(volume)" } ?? volume)
        } else {
            lines.append(l.format("progress.line.unknown", done))
        }
        var pace = l.speed(progress.currentSpeed)
        if let eta = progress.totalETA, progress.totalBytes != nil { pace += " · " + l.format("progress.remaining", l.duration(eta)) }
        if progress.currentSpeed > 0 || progress.totalETA != nil { lines.append(pace) }
        if let name = progress.currentName, !name.isEmpty { lines.append(name) }
        return lines
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

    /// Largeurs des colonnes, retenues d'une ouverture à l'autre (1.7.5).
    @State private var columns = ListColumns(from: .standard)

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(spacing: 0) {
            selectionBar
            TaskListHeader(columns: $columns, localizer: l) { columns.save(to: .standard) }
            List(selection: $selection) {
                ForEach(model.orderedTasks) { info in
                    TaskRow(info: info, task: model.tasks[info.id], progress: model.progress[info.id],
                            busy: model.busyTasks.contains(info.id), text: text, actions: actions(for: info.id), columns: columns)
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

/// En-tête de la liste (1.7.5) : titres des colonnes ; glisser un séparateur redimensionne la colonne à sa gauche,
/// un double-clic lui rend sa largeur d'origine.
@MainActor
struct TaskListHeader: View {
    @Binding var columns: ListColumns
    let localizer: Localizer
    let onChange: () -> Void
    @State private var dragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ListColumn.allCases, id: \.self) { column in
                title(column)
                if column != ListColumn.allCases.last { separator(after: column) }
            }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    @ViewBuilder private func title(_ column: ListColumn) -> some View {
        let label = Text(localizer.text(column.titleKey)).lineLimit(1)
        if column == .task {
            label.frame(minWidth: column.minimum, maxWidth: .infinity, alignment: .leading)
        } else {
            label.frame(width: columns.width(column), alignment: column == .rank || column == .actions ? .trailing : .leading)
        }
    }

    /// Séparateur entre `column` et la suivante : il agit sur la colonne redimensionnable la plus proche.
    @ViewBuilder private func separator(after column: ListColumn) -> some View {
        // Après Tâche (qui prend la place restante), le séparateur agit sur Horaire ; après N°, il ne fait rien.
        let target: ListColumn? = column.resizable ? column : (column == .task ? .schedule : nil)
        Rectangle().fill(Color.secondary.opacity(target == nil ? 0 : 0.35)).frame(width: 1, height: 14)
            .padding(.horizontal, (ListColumns.spacing - 1) / 2)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in if target != nil { inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard let target else { return }
                    let start = dragStart ?? columns.width(target)
                    if dragStart == nil { dragStart = start }
                    // Séparateur à droite de la colonne : glisser à droite l'élargit ; à gauche d'une colonne (après Tâche), l'inverse.
                    let sign: CGFloat = column.resizable ? 1 : -1
                    columns.resize(target, by: start + sign * value.translation.width - columns.width(target))
                }
                .onEnded { _ in dragStart = nil; onChange() })
            .onTapGesture(count: 2) { if let target { columns.reset(target); onChange() } }
            .help(localizer.text("list.column.reset"))
    }
}
