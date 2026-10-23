import AppKit
import SwiftUI
import SyncKit
import UniformTypeIdentifiers

/// Détails d'une exécution (1.8.2) : chaque fichier copié, mis à jour, supprimé ou archivé, avec sa taille.
@MainActor
struct RunDetailsView: View {
    let model: AgentModel
    let record: RunRecord
    let localizer: Localizer
    let onClose: () -> Void
    @State private var details: RunDetails?
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var query = ""

    enum Filter: Hashable, CaseIterable { case all, copied, deleted, touched }

    private var l: Localizer { localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l.format("details.title", record.taskName)).font(.headline).lineLimit(1)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(l.text(Self.filterKey($0))).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                TextField(l.text("details.search"), text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if let details {
                RunDetailsContent(details: details, filter: filter, query: query, localizer: l)
            } else if loaded {
                Text(l.text("details.none")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button(l.text("details.export")) { export() }.disabled(details?.rows.isEmpty ?? true)
                Spacer()
                Button(l.text("sheet.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 860, height: 560)
        .task {
            let found = await model.runDetails(record.id)
            details = (found?.rows.isEmpty ?? true) ? nil : found
            loaded = true
        }
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
        panel.nameFieldStringValue = "\(record.taskName) – détails.csv"
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
    @State private var order = [KeyPathComparator(\RunDetailRow.path)]

    private var l: Localizer { localizer }

    var body: some View {
        let rows = RunDetailsView.filtered(details.rows, filter: filter, query: query).sorted(using: order)
        VStack(alignment: .leading, spacing: 6) {
            Text(RunDetailsView.totalsLine(details, localizer: l)).font(.callout)
            if details.truncated {
                Text(l.format("details.truncated", details.rows.count)).font(.caption).foregroundStyle(.orange)
            }
            Table(rows, sortOrder: $order) {
                TableColumn(l.text("details.column.action"), value: \RunDetailRow.action.rawValue) { row in
                    Text(l.text(RunDetailsView.actionKey(row.action))).foregroundStyle(Self.color(row.action))
                }
                .width(min: 90, ideal: 110, max: 140)
                TableColumn(l.text("details.column.size"), value: \RunDetailRow.sortSize) { row in
                    Text(row.size.map { l.bytes($0) } ?? "—").monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 120)
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
