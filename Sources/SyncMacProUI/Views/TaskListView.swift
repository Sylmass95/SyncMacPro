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
        // 1.7.6 : horaire en étiquette au-dessus du nom, dernière exécution en couleur, seuls les boutons utiles.
        HStack(alignment: .top, spacing: ListColumns.spacing) {
            Text(row.rank(info)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: columns.width(.rank), alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let tag = row.scheduleTag(task, text: text) {
                    Text(tag).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(info.name).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(row.badges(info), id: \.self) { badge in
                        Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                if let task {
                    Text(row.route(task)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: ListColumn.task.minimum, maxWidth: columns.width(.task), alignment: .leading)
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.state(info, text: text)).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let progress, info.state == .running || info.state == .paused {
                    GlowProgressBar(value: Self.fraction(progress)).frame(height: 5)
                    ForEach(Array(Self.progressLines(progress, text: text).enumerated()), id: \.offset) { index, line in
                        Text(line).font(index == 2 ? .caption : .caption.monospacedDigit())
                            .foregroundStyle(index == 2 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.8)))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            .frame(width: columns.width(.state), alignment: .leading)
            lastRunView.frame(width: columns.width(.last), alignment: .leading)
            // La place libre reste devant les boutons (1.7.9).
            HStack(spacing: 4) { buttons }.controlSize(.small)
                .frame(minWidth: columns.width(.actions), maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(Self.opacity(for: info))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.rank(info)). \(info.name), \(row.state(info, text: text))")
    }

    private var lastRunView: some View {
        let last = row.lastRun(info, text: text)
        return VStack(alignment: .leading, spacing: 1) {
            Label(last.label, systemImage: last.symbol).font(.callout).foregroundStyle(Self.color(last.tone))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = last.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func color(_ tone: RowText.LastRun.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .failure: return .red
        case .warning: return .orange
        case .neutral: return .secondary
        }
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

    /// Boutons en icônes (1.7.6) : seuls ceux qui servent, leur nom au survol.
    @ViewBuilder private var buttons: some View {
        ForEach(Self.rowActions(info, task: task), id: \.self) { action in
            Button { perform(action) } label: {
                Image(systemName: action.symbol).frame(width: 14, height: 14)
                    .foregroundStyle(Self.tint(action))
            }
            .buttonStyle(.bordered)
            .help(l.text(action.tipKey)).accessibilityLabel(l.text(action.tipKey)).disabled(busy)
        }
    }

    /// Allumer/éteindre : vert quand la tâche est activée, gris sinon.
    static func tint(_ action: RowAction) -> Color {
        switch action {
        case .disable: return .green
        case .enable: return .gray
        default: return .primary
        }
    }

    private func perform(_ action: RowAction) {
        switch action {
        case .run: actions.run()
        case .resume: actions.resume()
        case .pause: actions.pause()
        case .force: actions.force()
        case .stop: actions.stop()
        case .abandon: actions.abandon()
        case .approve: actions.approve()
        case .eject: actions.eject()
        case .enable: actions.setEnabled(true)
        case .disable: actions.setEnabled(false)
        }
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

    /// Double-clic (1.7.6) : la fiche de la première tâche sélectionnée, dans l'ordre de la liste.
    static func taskToOpen<S: Sequence>(_ ids: S, order: [UUID]) -> UUID? where S.Element == UUID {
        let chosen = Set(ids).subtracting([otherRunsID])
        return order.first { chosen.contains($0) }
    }

    /// Ouvre la fiche d'une tâche (Configuration · Réglages · Journal).
    var onOpen: (UUID) -> Void = { _ in }

    /// 1.8.0 : gérer une tâche depuis le clic droit (l'écran Tâches a rejoint le tableau de bord).
    enum ManageAction: Hashable { case edit, duplicate, delete }

    /// Modifier, Dupliquer et Supprimer : pour une seule tâche enregistrée (pas une copie ponctuelle).
    static func manageActions<S: Sequence>(_ ids: S, tasks: [UUID]) -> [ManageAction] where S.Element == UUID {
        let chosen = Set(ids).subtracting([otherRunsID])
        guard chosen.count == 1, let id = chosen.first, tasks.contains(id) else { return [] }
        return [.edit, .duplicate, .delete]
    }

    var onManage: (ManageAction, UUID) -> Void = { _, _ in }

    /// Largeurs des colonnes, retenues d'une ouverture à l'autre (1.7.5).
    @State private var columns = ListColumns(from: .standard)
    @State private var headerColumns = ListColumns(from: .standard)

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(spacing: 0) {
            // Pendant un glissement, seul l'en-tête suit la souris ; la liste suit au lâcher (1.7.9 : sinon chaque
            // déplacement redessine toutes les lignes et le trait traîne).
            TaskListHeader(columns: $headerColumns, localizer: l) {
                columns = headerColumns
                columns.save(to: .standard)
            }
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
            .contextMenu(forSelectionType: UUID.self) { ids in
                groupActions(ids)
                let manage = Self.manageActions(ids, tasks: Array(model.tasks.keys))
                if let id = ids.first, !manage.isEmpty {
                    Divider()
                    Button { onManage(.edit, id) } label: { Label(l.text("list.edit"), systemImage: "pencil") }
                    Button { onManage(.duplicate, id) } label: { Label(l.text("list.duplicate"), systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { onManage(.delete, id) } label: { Label(l.text("tasks.delete"), systemImage: "trash") }
                }
            } primaryAction: { ids in
                if let id = Self.taskToOpen(ids, order: model.orderedTasks.map(\.id)) { onOpen(id) }
            }
        }
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
            eject: { Task { await model.ejectDrive(id) } },
            setEnabled: { on in Task { await model.setEnabled(id, on) } }
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
    /// Largeur des colonnes (sans les marges), pour que Tâche garde son minimum.
    @State private var available: CGFloat = 10_000

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ListColumn.allCases, id: \.self) { column in
                title(column)
                if column != ListColumn.allCases.last { separator(after: column) }
            }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { available = proxy.size.width - 32 }
                .onChange(of: proxy.size.width) { _, width in available = width - 32 }
        })
    }

    @ViewBuilder private func title(_ column: ListColumn) -> some View {
        let label = Text(localizer.text(column.titleKey)).lineLimit(1)
        if column == .task {
            label.frame(minWidth: column.minimum, maxWidth: columns.width(.task), alignment: .leading).layoutPriority(1)
        } else if column == .actions {
            label.frame(minWidth: columns.width(.actions), maxWidth: .infinity, alignment: .trailing)
        } else {
            label.frame(width: columns.width(column), alignment: column == .rank || column == .actions ? .trailing : .leading)
        }
    }

    /// Séparateur après `column` : il tire son bord droit (1.7.9).
    @ViewBuilder private func separator(after column: ListColumn) -> some View {
        let target = ListColumns.separatorTarget(after: column)
        Rectangle().fill(Color.secondary.opacity(target == nil ? 0 : 0.35)).frame(width: 1, height: 14)
            .padding(.horizontal, (ListColumns.spacing - 1) / 2)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in if target != nil { inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    guard let target else { return }
                    let start = dragStart ?? columns.width(target)
                    if dragStart == nil { dragStart = start }
                    columns.drag(target, from: start, translation: value.translation.width, available: available)
                }
                .onEnded { _ in dragStart = nil; onChange() })
            .onTapGesture(count: 2) { if let target { columns.reset(target); onChange() } }
            .help(localizer.text("list.column.reset"))
    }
}
