import AppKit
import SwiftUI
import SyncKit
import UniformTypeIdentifiers

/// Ce qu'il faut pour ouvrir les détails d'une exécution dans leur propre fenêtre (1.8.3).
public struct RunDetailsTarget: Codable, Hashable, Sendable {
    public var runID: UUID
    public var taskID: UUID
    public var taskName: String
    public var startedAt: Date

    public init(record: RunRecord) {
        runID = record.id
        taskID = record.taskID
        taskName = record.taskName
        startedAt = record.startedAt
    }
}

/// Détails d'une exécution (1.8.2) : chaque fichier copié, mis à jour, supprimé ou archivé, avec sa taille, d'où il vient
/// et où il va (1.8.3) ; fenêtre à part, redimensionnable.
@MainActor
public struct RunDetailsView: View {
    let model: AgentModel
    let target: RunDetailsTarget
    let localizer: Localizer
    @State private var details: RunDetails?
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var selected: RunDetailRow.ID?
    @Environment(\.dismiss) private var dismiss

    public init(model: AgentModel, target: RunDetailsTarget, localizer: Localizer) {
        self.model = model
        self.target = target
        self.localizer = localizer
    }

    enum Filter: Hashable, CaseIterable { case all, copied, deleted, touched }

    private var l: Localizer { localizer }
    private var task: SyncTask? { model.tasks[target.taskID] }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l.format("details.title", target.taskName)).font(.headline).lineLimit(1)
                Text(CardText(localizer: l).nextRun(target.startedAt)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(l.text(Self.filterKey($0))).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                TextField(l.text("details.search"), text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if let details {
                RunDetailsContent(details: details, filter: filter, query: query, localizer: l, task: task, selection: $selected)
                pathBar(details)
            } else if loaded {
                Text(l.text("details.none")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button(l.text("details.export")) { export() }.disabled(details?.rows.isEmpty ?? true)
                Spacer()
                Button(l.text("sheet.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 1100, minHeight: 420, idealHeight: 680)
        .task {
            let found = await model.runDetails(target.runID)
            details = (found?.rows.isEmpty ?? true) ? nil : found
            loaded = true
        }
    }

    /// Le chemin complet du fichier choisi (sélectionnable) et, s'il est sur le Mac ou un partage monté, le Finder.
    @ViewBuilder private func pathBar(_ details: RunDetails) -> some View {
        if let id = selected, let row = details.rows.first(where: { $0.id == id }) {
            let full = Self.fullPath(row, task: task)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.whereText(row, task: task, localizer: l)).font(.caption).foregroundStyle(.secondary)
                Text(full ?? row.path).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let full, row.action != .archived, row.action != .deleted, FileManager.default.fileExists(atPath: full) {
                    Button(l.text("details.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)]) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        } else {
            Text(l.text("details.select")).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Le côté de la tâche où le fichier se trouvait : la source ou la destination (rsync), le service en ligne ou le
    /// disque (rclone).
    static func side(_ origin: RunDetailRow.Origin?, task: SyncTask) -> Endpoint? {
        let cloudSides = [task.source, task.destination].filter(\.isCloud)
        switch origin {
        case .source: return task.source
        case .destination: return task.destination
        case .cloud: return cloudSides.count == 1 ? cloudSides[0] : nil
        case .local: return cloudSides.count == 1 ? (task.source.isCloud ? task.destination : task.source) : nil
        case nil: return nil
        }
    }

    /// « NAS « 01_PROJETS_ACTIFS » → Drive partagé » pour une copie, « sur Drive partagé » pour le reste.
    static func whereText(_ row: RunDetailRow, task: SyncTask?, localizer l: Localizer) -> String {
        guard let task, let side = side(row.origin, task: task) else { return "" }
        let text = RowText(localizer: l)
        func place(_ endpoint: Endpoint) -> String { text.place(endpoint, drive: endpoint == task.destination ? task.removableDrive : nil) }
        switch row.action {
        case .added, .updated:
            let other = side == task.source ? task.destination : task.source
            return "\(place(side)) → \(place(other))"
        case .deleted, .archived, .touched:
            return l.format("details.where.on", place(side))
        }
    }

    /// Chemin complet sur le Mac (dossier ou partage monté) du côté d'où vient le fichier ; `nil` en ligne.
    static func fullPath(_ row: RunDetailRow, task: SyncTask?) -> String? {
        guard let task, let side = side(row.origin, task: task), let root = side.filesystemPath else { return nil }
        return Endpoint.join(root, row.path)
    }

    static func filterKey(_ filter: Filter) -> String {
        switch filter {
        case .all: return "details.filter.all"
        case .copied: return "details.filter.copied"
        case .deleted: return "details.filter.deleted"
        case .touched: return "details.filter.touched"
        }
    }

    /// Lignes du filtre choisi dont le chemin contient la recherche (sans tenir compte des accents ni des majuscules).
    static func filtered(_ rows: [RunDetailRow], filter: Filter, query: String) -> [RunDetailRow] {
        let wanted: Set<RunDetailRow.Action>
        switch filter {
        case .all: wanted = Set(RunDetailRow.Action.allCases)
        case .copied: wanted = [.added, .updated]
        case .deleted: wanted = [.deleted, .archived]
        case .touched: wanted = [.touched]
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return rows.filter { row in
            wanted.contains(row.action)
                && (needle.isEmpty || row.path.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    static func actionKey(_ action: RunDetailRow.Action) -> String { "details.action.\(action.rawValue)" }

    /// « 12 nouveau(x) (3,2 Go) · 2 mis à jour (40 Ko) · 1 supprimé(s) ».
    static func totalsLine(_ details: RunDetails, localizer l: Localizer) -> String {
        RunDetailRow.Action.allCases.compactMap { action -> String? in
            guard let total = details.totals[action], total.count > 0 else { return nil }
            switch action {
            case .added, .updated: return l.format("details.total.\(action.rawValue)", total.count, l.bytes(total.bytes))
            case .deleted, .archived, .touched: return l.format("details.total.\(action.rawValue)", total.count)
            }
        }.joined(separator: " · ")
    }

    /// CSV séparé par des points-virgules (Excel en français) ; un champ avec « ; », « " » ou un retour est cité.
    static func csv(_ rows: [RunDetailRow], localizer l: Localizer) -> String {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == ";" || $0 == "\"" || $0.isNewline }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let header = [l.text("details.column.action"), l.text("details.column.bytes"), l.text("details.column.path")].joined(separator: ";")
        let lines = rows.map { [field(l.text(actionKey($0.action))), $0.size.map(String.init) ?? "", field($0.path)].joined(separator: ";") }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    private func export() {
        guard let details else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(target.taskName) – détails.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = Self.filtered(details.rows, filter: filter, query: query)
        try? Self.csv(rows, localizer: l).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Totaux et tableau (triable) : séparé de la feuille pour être rendu par les tests.
@MainActor
struct RunDetailsContent: View {
    let details: RunDetails
    let filter: RunDetailsView.Filter
    let query: String
    let localizer: Localizer
    var task: SyncTask?
    var selection: Binding<RunDetailRow.ID?> = .constant(nil)
    @State private var order = [KeyPathComparator(\RunDetailRow.path)]

    private var l: Localizer { localizer }

    var body: some View {
        let rows = RunDetailsView.filtered(details.rows, filter: filter, query: query).sorted(using: order)
        VStack(alignment: .leading, spacing: 6) {
            Text(RunDetailsView.totalsLine(details, localizer: l)).font(.callout)
            if details.truncated {
                Text(l.format("details.truncated", details.rows.count)).font(.caption).foregroundStyle(.orange)
            }
            Table(rows, selection: selection, sortOrder: $order) {
                TableColumn(l.text("details.column.action"), value: \RunDetailRow.action.rawValue) { row in
                    Text(l.text(RunDetailsView.actionKey(row.action))).foregroundStyle(Self.color(row.action))
                }
                .width(min: 90, ideal: 110, max: 140)
                TableColumn(l.text("details.column.size"), value: \RunDetailRow.sortSize) { row in
                    Text(row.size.map { l.bytes($0) } ?? "—").monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn(l.text("details.column.where")) { row in
                    Text(RunDetailsView.whereText(row, task: task, localizer: l)).foregroundStyle(.secondary).help(RunDetailsView.whereText(row, task: task, localizer: l))
                }
                .width(min: 120, ideal: 220, max: 360)
                TableColumn(l.text("details.column.path"), value: \RunDetailRow.path) { row in
                    Text(row.path).textSelection(.enabled).help(row.path)
                }
            }
        }
    }

    static func color(_ action: RunDetailRow.Action) -> Color {
        switch action {
        case .added: return .green
        case .updated: return .blue
        case .deleted: return .red
        case .archived: return .orange
        case .touched: return .secondary
        }
    }
}

extension RunDetailRow: Identifiable {
    public var id: String { "\(action.rawValue)|\(path)" }
    var sortSize: Int64 { size ?? -1 }
}
