import SwiftUI
import SyncKit

struct TaskCardActions {
    var run: () -> Void = {}
    var pause: () -> Void = {}
    var resume: () -> Void = {}
    var stop: () -> Void = {}
    var approve: () -> Void = {}
    var enqueue: () -> Void = {}
    var dequeue: () -> Void = {}
}

@MainActor
struct TaskCard: View {
    let info: AgentTaskInfo
    /// `nil` tant que `listTasks` ne connaît pas la tâche : la carte reste affichable, sans mode ni planification.
    let task: SyncTask?
    let progress: ProgressInfo?
    let busy: Bool
    let text: CardText
    let actions: TaskCardActions

    private var l: Localizer { text.localizer }
    private var isActive: Bool { info.state == .running || info.state == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.name).font(.headline).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                StatePill(state: info.state, label: text.state(info.state))
            }
            if let task {
                Text("\(text.mode(task.mode)) · \(text.schedule(task.schedule))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if info.isOneOff {
                Label(l.text("card.oneoff"), systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
            }
            if let position = info.queuePosition {
                Label(l.format("card.inqueue", position), systemImage: "list.number").font(.caption.bold()).foregroundStyle(.blue)
            }
            if isActive { progressSection }
            if info.state == .awaitingApproval {
                Text(l.format("card.approval.body", info.lastRun?.summary?.message ?? ""))
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(l.format("card.last", text.lastRun(info.lastRun)))
                if !isActive, let summary = info.lastRun?.summary, info.lastRun?.status != .running,
                   summary.directories != nil || summary.averageSpeed != nil {
                    Text(ProgressPresentation(localizer: l).summaryLines(summary).joined(separator: " · "))
                }
                if let next = text.nextRunLine(info: info, task: task) { Text(next) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack { buttons }.controlSize(.small)
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(info.name), \(text.state(info.state))")
    }

    @ViewBuilder private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress {
                GlowProgressBar(value: fraction(progress))
                    .accessibilityLabel(l.text("state.running"))
                    .accessibilityValue("\(progress.overallPercent ?? Int(fraction(progress) * 100)) %")
                Text(text.progressLine(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                TaskProgressDetails(progress: progress, presentation: ProgressPresentation(localizer: l))
                if let name = progress.currentName {
                    Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func fraction(_ info: ProgressInfo) -> Double {
        if let percent = info.overallPercent { return min(1, max(0, Double(percent) / 100)) }
        guard let total = info.totalBytes, total > 0 else { return 0 }
        return min(1, Double(info.doneBytes) / Double(total))
    }

    @ViewBuilder private var buttons: some View {
        switch info.state {
        case .running:
            button("card.pause", "pause.fill", actions.pause)
            button("card.stop", "stop.fill", actions.stop)
        case .paused:
            button("card.resume", "play.fill", actions.resume)
            button("card.stop", "stop.fill", actions.stop)
        case .queued:
            button("card.stop", "stop.fill", actions.stop)
        case .awaitingApproval:
            Button(action: actions.approve) { Label(l.text("card.approve"), systemImage: "checkmark.shield") }
                .buttonStyle(GlassButtonStyle(prominent: true)).disabled(busy)
            button("card.run", "play.fill", actions.run)
        case .idle, .waiting, .disabled:
            button("card.run", "play.fill", actions.run)
            if info.isOneOff == false {
                if info.queuePosition == nil {
                    button("card.enqueue", "text.badge.plus", actions.enqueue)
                } else {
                    button("queue.remove", "text.badge.minus", actions.dequeue)
                }
            }
        }
    }

    private func button(_ key: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(l.text(key), systemImage: symbol) }.disabled(busy)
    }
}
