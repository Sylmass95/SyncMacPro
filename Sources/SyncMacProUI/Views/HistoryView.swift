import SwiftUI
import SyncKit

/// 1.7.0 : plus d'écran Historique global ; le tableau sert à l'onglet Historique du détail d'une tâche.
@MainActor
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
                .background(.regularMaterial)
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
