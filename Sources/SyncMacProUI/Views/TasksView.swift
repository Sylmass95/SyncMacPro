import SwiftUI
import SyncKit

/// Liste des tâches : activer, modifier, dupliquer, supprimer, créer (vide ou depuis un modèle).
@MainActor
public struct TasksView: View {
    let model: AgentModel
    let localizer: Localizer
    let onEdit: (TaskDraft, Bool) -> Void
    @State private var selection: UUID?
    @State private var pendingDelete: SyncTask?

    public init(model: AgentModel, localizer: Localizer = .system, onEdit: @escaping (TaskDraft, Bool) -> Void) {
        self.model = model
        self.localizer = localizer
        self.onEdit = onEdit
    }

    private var tasks: [SyncTask] {
        model.tasks.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var body: some View {
        let text = CardText(localizer: localizer)
        VStack(spacing: 0) {
            HStack {
                Text(localizer.text("tasks.title")).font(.largeTitle.bold())
                Spacer()
                TemplatesMenu(localizer: localizer) { onEdit(.template($0), true) }
                Button { onEdit(TaskDraft(), true) } label: { Label(localizer.text("tasks.new"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.connection != .connected)
            }
            .padding(20)
            Divider()
            if tasks.isEmpty {
                Spacer()
                Text(localizer.text("tasks.empty")).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    TasksListBody(
                        tasks: tasks, selection: selection, text: text,
                        onToggle: { task, on in Task { await model.setEnabled(task.id, on) } },
                        onEdit: { onEdit(TaskDraft(task: $0), false) },
                        onDuplicate: { onEdit(.duplicate(of: $0, suffix: localizer.text("tasks.copy.suffix")), true) },
                        onDelete: { pendingDelete = $0 },
                        onSelect: { selection = $0 }
                    )
                }
            }
        }
        .confirmationDialog(
            pendingDelete.map { localizer.format("tasks.delete.confirm", $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { task in
            Button(localizer.text("tasks.delete"), role: .destructive) { Task { await model.removeTask(task.id) } }
        } message: { _ in
            Text(localizer.text("tasks.delete.body"))
        }
    }
}

@MainActor
struct TemplatesMenu: View {
    let localizer: Localizer
    let onPick: (TaskTemplate) -> Void

    var body: some View {
        let text = TaskSummaryText(localizer: localizer)
        Menu(localizer.text("tasks.templates")) {
            ForEach(TaskTemplate.allCases) { template in
                Button {
                    onPick(template)
                } label: {
                    Text(text.templateTitle(template))
                    Text(text.templateDescription(template))
                }
            }
        }
        .fixedSize()
    }
}

/// Les lignes de la liste, sans défilement (rendu par les tests).
@MainActor
struct TasksListBody: View {
    let tasks: [SyncTask]
    let selection: UUID?
    let text: CardText
    let onToggle: (SyncTask, Bool) -> Void
    let onEdit: (SyncTask) -> Void
    let onDuplicate: (SyncTask) -> Void
    let onDelete: (SyncTask) -> Void
    let onSelect: (UUID) -> Void

    private var l: Localizer { text.localizer }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tasks) { task in
                row(task)
                Divider()
            }
        }
    }

    private func row(_ task: SyncTask) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).font(.headline).lineLimit(1)
                Text("\(text.mode(task.mode)) · \(text.schedule(task.schedule))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Toggle(l.text("tasks.enabled"), isOn: Binding(get: { task.isEnabled }, set: { onToggle(task, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
            Menu {
                Button(l.text("tasks.edit")) { onEdit(task) }
                Button(l.text("tasks.duplicate")) { onDuplicate(task) }
                Divider()
                Button(l.text("tasks.delete"), role: .destructive) { onDelete(task) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(selection == task.id ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit(task) }
        .onTapGesture { onSelect(task.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.name)
    }
}
