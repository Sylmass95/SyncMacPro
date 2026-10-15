import SwiftUI
import SyncKit

/// La file d'attente : ordre, monter / descendre, retirer, lancer / suspendre.
@MainActor
public struct QueueSection: View {
    let model: AgentModel
    let localizer: Localizer
    /// Miniature : sans la carte de verre ni le titre en gras.
    var compact = false

    public init(model: AgentModel, localizer: Localizer, compact: Bool = false) {
        self.model = model
        self.localizer = localizer
        self.compact = compact
    }

    private var names: [UUID: String] {
        Dictionary((model.status?.tasks ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    public var body: some View {
        let queue = model.queue ?? QueueInfo(running: false, items: [], current: nil)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(localizer.text("queue.title"), systemImage: "list.number").font(compact ? .callout.bold() : .headline)
                Spacer()
                Button(queue.running ? localizer.text("queue.suspend") : localizer.text("queue.start")) {
                    Task { await model.setQueueRunning(!queue.running) }
                }
                .buttonStyle(GlassButtonStyle(prominent: !queue.running))
                .controlSize(.small)
                .disabled(model.connection != .connected || (queue.items.isEmpty && !queue.running))
            }
            if let current = queue.current, let name = names[current] {
                Label(localizer.format("queue.current", name), systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
            }
            if queue.items.isEmpty {
                Text(localizer.text("queue.empty")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(queue.items.enumerated()), id: \.element) { index, id in
                HStack(spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(names[id] ?? id.uuidString).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { Task { await model.moveInQueue(id, by: -1) } } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).help(localizer.text("queue.up"))
                    Button { Task { await model.moveInQueue(id, by: 1) } } label: { Image(systemName: "chevron.down") }
                        .disabled(index == queue.items.count - 1).help(localizer.text("queue.down"))
                    Button { Task { await model.dequeue(id) } } label: { Image(systemName: "xmark") }
                        .help(localizer.text("queue.remove"))
                }
                .font(.callout)
                .buttonStyle(.borderless)
            }
        }
        .padding(compact ? 10 : 14)
        .glassCard(cornerRadius: compact ? 12 : 16, dense: compact)
    }
}

/// Lignes de progression façon RsyncGUI sous la barre d'une carte : fichiers, dossiers, vitesse moyenne, temps écoulé.
@MainActor
struct TaskProgressDetails: View {
    let progress: ProgressInfo
    let presentation: ProgressPresentation

    static func lines(_ progress: ProgressInfo, presentation: ProgressPresentation) -> [String] {
        var lines = [presentation.filesLine(done: progress.filesDone, total: progress.totalFiles)]
        if let dirs = presentation.dirsLine(done: progress.dirsDone, total: progress.totalDirs) { lines.append(dirs) }
        if let average = presentation.averageSpeedLine(progress.averageSpeed) { lines.append(average) }
        lines.append(presentation.elapsedLine(progress.activeTime))
        return lines
    }

    var body: some View {
        let lines = Self.lines(progress, presentation: presentation)
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 2) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
