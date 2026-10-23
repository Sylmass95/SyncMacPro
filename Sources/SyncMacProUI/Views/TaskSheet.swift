import SwiftUI
import SyncKit

/// Fiche d'une tâche, ouverte d'un double-clic sur sa ligne (1.7.6) : Configuration (l'éditeur complet), Réglages
/// (l'essentiel), Journal.
@MainActor
struct TaskSheet: View {
    let model: AgentModel
    let taskID: UUID
    let text: CardText
    let onClose: () -> Void

    enum Tab: Hashable { case configuration, settings, log }

    @State var tab: Tab = .settings

    private var l: Localizer { text.localizer }

    var body: some View {
        let info = model.orderedTasks.first { $0.id == taskID }
        let task = model.tasks[taskID]
        VStack(spacing: 0) {
            HStack {
                Text(info?.name ?? task?.name ?? "").font(.headline).lineLimit(1)
                Spacer()
                Picker("", selection: $tab) {
                    if task != nil {
                        Text(l.text("sheet.tab.config")).tag(Tab.configuration)
                        Text(l.text("detail.tab.settings")).tag(Tab.settings)
                    }
                    Text(l.text("detail.tab.log")).tag(Tab.log)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button(l.text("sheet.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            switch Self.effectiveTab(tab, hasTask: task != nil) {
            case .configuration:
                if let task {
                    // Annuler ou Enregistrer dans l'éditeur ferme la fiche.
                    TaskEditorView(model: model, draft: TaskDraft(task: task), isNew: false, localizer: l, onClose: onClose)
                }
            case .settings:
                if let task {
                    TaskSettingsTab(model: model, task: task, localizer: l, onEdit: { _ in tab = .configuration })
                        .id(TaskSettingsTab.identity(task))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            case .log:
                TaskLogTab(model: model, record: info?.lastRun, localizer: l).padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 740, height: 680)
    }

    /// Une copie ponctuelle n'a ni configuration ni réglages : seul son journal s'affiche.
    static func effectiveTab(_ tab: Tab, hasTask: Bool) -> Tab { hasTask ? tab : .log }
}
