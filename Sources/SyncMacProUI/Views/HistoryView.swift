import SwiftUI
import SyncKit

public struct HistoryView: View {
    let model: AgentModel
    let localizer: Localizer
    let now: Date?
    @State private var filter: HistoryFilter
    @State private var selection: UUID?

    public init(
        model: AgentModel, localizer: Localizer = .system, filter: HistoryFilter = HistoryFilter(),
        selection: UUID? = nil, now: Date? = nil
    ) {
        self.model = model
        self.localizer = localizer
        self.now = now
        _filter = State(initialValue: filter)
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        let text = CardText(localizer: localizer, now: now ?? Date())
        let rows = filter.apply(to: model.history, now: text.now)
        VStack(spacing: 0) {
            filterBar(text)
            Divider()
            if let error = model.historyError {
                Banner(
                    systemImage: "exclamationmark.triangle", tint: .red,
                    title: localizer.format("history.error", error)
                ) {
                    Button(localizer.text("connection.retry")) { Task { await model.reloadHistory() } }
                }
                .padding(12)
            }
            if rows.isEmpty {
                Spacer()
                Text(model.history.isEmpty ? localizer.text("history.empty") : localizer.text("history.empty.filtered"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                table(rows, text)
            }
            Divider()
            detail(rows, text)
        }
    }

    // MARK: filtres

    private func filterBar(_ text: CardText) -> some View {
        HStack(spacing: 12) {
            Picker(localizer.text("history.filter.task"), selection: $filter.taskID) {
                Text(localizer.text("history.filter.alltasks")).tag(UUID?.none)
                ForEach(taskChoices, id: \.0) { Text($0.1).tag(UUID?.some($0.0)) }
            }
            .frame(maxWidth: 220)
            Menu {
                ForEach(RunStatus.allCases, id: \.self) { status in
                    Toggle(text.status(status), isOn: binding(for: status))
                }
            } label: {
                Text(
                    filter.statuses.isEmpty
                        ? localizer.text("history.filter.allstatus")
                        : "\(localizer.text("history.filter.status")) (\(filter.statuses.count))"
                )
            }
            .frame(maxWidth: 170)
            Picker("", selection: $filter.period) {
                ForEach(HistoryPeriod.allCases, id: \.self) { Text(periodLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
            TextField(localizer.text("history.search"), text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
        }
        .padding(12)
    }

    private var taskChoices: [(UUID, String)] {
        var seen = Set<UUID>()
        var choices: [(UUID, String)] = []
        for record in model.history where seen.insert(record.taskID).inserted {
            choices.append((record.taskID, record.taskName))
        }
        return choices.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func binding(for status: RunStatus) -> Binding<Bool> {
        Binding(
            get: { filter.statuses.contains(status) },
            set: { isOn in
                if isOn { filter.statuses.insert(status) } else { filter.statuses.remove(status) }
            }
        )
    }

    private func periodLabel(_ period: HistoryPeriod) -> String {
        switch period {
        case .day: return localizer.text("history.period.day")
        case .week: return localizer.text("history.period.week")
        case .month: return localizer.text("history.period.month")
        case .all: return localizer.text("history.period.all")
        }
    }

    // MARK: tableau

    private func table(_ rows: [RunRecord], _ text: CardText) -> some View {
        ScrollView {
            HistoryTableBody(
                rows: rows, selection: selection, text: text, localizer: localizer,
                onSelect: { selection = $0 }
            )
        }
        .focusable()
        .onMoveCommand { direction in move(direction, in: rows) }
    }

    private func move(_ direction: MoveCommandDirection, in rows: [RunRecord]) {
        guard !rows.isEmpty else { return }
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        switch direction {
        case .down: selection = rows[min((current ?? -1) + 1, rows.count - 1)].id
        case .up: selection = rows[max((current ?? rows.count) - 1, 0)].id
        default: break
        }
    }

    // MARK: détail

    @ViewBuilder
    private func detail(_ rows: [RunRecord], _ text: CardText) -> some View {
        Group {
            if let record = rows.first(where: { $0.id == selection }) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text(localizer.text("history.column.task")).foregroundStyle(.secondary)
                        Text("\(record.taskName) — \(text.status(record.status))").bold()
                    }
                    GridRow {
                        Text(localizer.text("history.detail.engine")).foregroundStyle(.secondary)
                        Text("\(record.engine.rawValue) · \(text.mode(record.mode))")
                    }
                    GridRow {
                        Text(localizer.text("history.detail.started")).foregroundStyle(.secondary)
                        Text(text.dateTime(record.startedAt))
                    }
                    if let end = record.finishedAt {
                        GridRow {
                            Text(localizer.text("history.detail.finished")).foregroundStyle(.secondary)
                            Text(text.dateTime(end))
                        }
                    }
                    GridRow {
                        Text(localizer.text("history.column.files")).foregroundStyle(.secondary)
                        Text(text.summaryLine(record.summary))
                    }
                    if let message = record.summary?.message, !message.isEmpty {
                        GridRow(alignment: .top) {
                            Text(localizer.text("history.detail.message")).foregroundStyle(.secondary)
                            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
            } else {
                Text(localizer.text("history.detail.none")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(12)
    }
}

/// Le tableau (en-tête épinglé + lignes) sans son défilement : `ImageRenderer` ne dessine pas un `ScrollView`.
struct HistoryTableBody: View {
    let rows: [RunRecord]
    let selection: UUID?
    let text: CardText
    let localizer: Localizer
    let onSelect: (UUID) -> Void

    private enum Column {
        static let date: CGFloat = 150, status: CGFloat = 110, duration: CGFloat = 70
        static let files: CGFloat = 70, size: CGFloat = 90, errors: CGFloat = 60
    }

    var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(rows) { record in
                    row(record)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(record.id) }
                }
            } header: {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        header(localizer.text("history.column.date"), width: Column.date)
                        header(localizer.text("history.column.task"), width: nil)
                        header(localizer.text("history.column.status"), width: Column.status)
                        header(localizer.text("history.column.duration"), width: Column.duration)
                        header(localizer.text("history.column.files"), width: Column.files)
                        header(localizer.text("history.column.size"), width: Column.size)
                        header(localizer.text("history.column.errors"), width: Column.errors)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                .background(.background)
            }
        }
    }

    private func header(_ title: String, width: CGFloat?) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ record: RunRecord) -> some View {
        let summary = record.summary
        return HStack(spacing: 8) {
            Text(text.dateTime(record.startedAt)).frame(width: Column.date, alignment: .leading)
            Text(record.taskName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(text.status(record.status)).foregroundStyle(color(record.status)).frame(width: Column.status, alignment: .leading)
            Text(durationText(record)).frame(width: Column.duration, alignment: .leading)
            Text("\(summary?.filesTransferred ?? 0)").frame(width: Column.files, alignment: .leading)
            Text(localizer.bytes(summary?.bytesTransferred ?? 0)).frame(width: Column.size, alignment: .leading)
            Text("\(summary?.errors ?? 0)").frame(width: Column.errors, alignment: .leading)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selection == record.id ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == record.id ? .isSelected : [])
    }

    private func color(_ status: RunStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .failed, .blocked, .quotaReached: return .red
        case .running: return .blue
        case .interrupted, .stopped: return .orange
        }
    }

    private func durationText(_ record: RunRecord) -> String {
        if let seconds = record.summary?.durationSeconds, record.status != .running, seconds > 0 {
            return localizer.duration(seconds)
        }
        if let end = record.finishedAt { return localizer.duration(end.timeIntervalSince(record.startedAt)) }
        return "—"
    }
}
