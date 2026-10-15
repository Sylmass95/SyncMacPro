import SwiftUI
import SyncKit

/// La miniature : une carte par transfert en cours, puis la file. Toujours au premier plan (voir `MiniPanelController`).
@MainActor
public struct MiniView: View {
    let model: AgentModel
    let localizer: Localizer
    let onExpand: () -> Void

    public init(model: AgentModel, localizer: Localizer, onExpand: @escaping () -> Void) {
        self.model = model
        self.localizer = localizer
        self.onExpand = onExpand
    }

    static func runningIDs(_ status: AgentStatus?) -> [UUID] {
        (status?.tasks ?? []).filter { $0.state == .running || $0.state == .paused }.map(\.id)
    }

    public var body: some View {
        ScrollView { MiniBody(model: model, localizer: localizer, onExpand: onExpand) }
            .frame(minWidth: 340, minHeight: 160)
            .background(GlassBackdrop())
    }
}

/// Le contenu sans défilement (rendu par les tests).
@MainActor
struct MiniBody: View {
    let model: AgentModel
    let localizer: Localizer
    let onExpand: () -> Void

    var body: some View {
        let text = CardText(localizer: localizer)
        let ids = MiniView.runningIDs(model.status)
        let infos = (model.status?.tasks ?? []).filter { ids.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localizer.text("mini.title")).font(.headline)
                Spacer()
                Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help(localizer.text("mini.expand"))
            }
            if model.connection != .connected {
                Text(localizer.text("mini.offline")).font(.callout).foregroundStyle(.secondary)
            } else if infos.isEmpty {
                Text(localizer.text("mini.idle")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(infos) { info in
                TaskCard(
                    info: info, task: model.tasks[info.id], progress: model.progress[info.id] ?? info.progress,
                    busy: model.busyTasks.contains(info.id), text: text,
                    actions: TaskCardActions(
                        pause: { Task { await model.pause(info.id) } },
                        resume: { Task { await model.resume(info.id) } },
                        stop: { Task { await model.stop(info.id) } }
                    )
                )
            }
            if model.queue?.items.isEmpty == false {
                QueueSection(model: model, localizer: localizer, compact: true)
            }
        }
        .padding(12)
    }
}
