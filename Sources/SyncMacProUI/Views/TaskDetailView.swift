import SwiftUI
import SyncKit

/// Détail de la sélection, sous la liste (1.7.0) : Historique, Réglages (l'essentiel), Journal.
@MainActor
struct TaskDetailView: View {
    let model: AgentModel
    let selection: Set<UUID>
    let text: CardText
    let onEdit: (SyncTask) -> Void

    enum Mode: Equatable {
        case empty
        case several(Int)
        case otherRuns
        case task(UUID)

        /// Historique à charger : une tâche, ou `nil` pour les exécutions sans tâche ; rien si `nil` tout court.
        var historyTarget: UUID?? {
            switch self {
            case .task(let id): return .some(id)
            case .otherRuns: return .some(nil)
            case .empty, .several: return nil
            }
        }
    }

    static func mode(for selection: Set<UUID>) -> Mode {
        let tasks = selection.subtracting([TaskListView.otherRunsID])
        if tasks.count > 1 { return .several(tasks.count) }
        if let id = tasks.first { return .task(id) }
        return selection.contains(TaskListView.otherRunsID) ? .otherRuns : .empty
    }

    enum Tab: Hashable { case history, settings, log }
    @State private var tab: Tab = .history

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch Self.mode(for: selection) {
            case .empty:
                Text(l.text("detail.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .several(let count):
                Text(l.format("list.selection.count", count)).font(.headline)
                Text(l.text("detail.several")).foregroundStyle(.secondary)
            case .otherRuns:
                Text(l.text("list.otherRuns")).font(.headline)
                TaskHistoryTab(model: model, taskID: nil, reloadKey: nil, text: text)
            case .task(let id):
                let info = model.orderedTasks.first { $0.id == id }
                HStack {
                    Text(info?.name ?? "").font(.headline).lineLimit(1)
                    Spacer()
                    Picker("", selection: $tab) {
                        Text(l.text("detail.tab.history")).tag(Tab.history)
                        if model.tasks[id] != nil { Text(l.text("detail.tab.settings")).tag(Tab.settings) }
                        Text(l.text("detail.tab.log")).tag(Tab.log)
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
                switch tab {
                case .history: TaskHistoryTab(model: model, taskID: id, reloadKey: info?.lastRun?.id, text: text)
                case .settings:
                    if let task = model.tasks[id] {
                        TaskSettingsTab(model: model, task: task, localizer: l, onEdit: onEdit).id(task.id)
                    }
                case .log: TaskLogTab(model: model, record: info?.lastRun, localizer: l)
                }
            }
        }
        .padding(12)
    }
}

/// Exécutions d'une tâche (ou sans tâche), rechargées à chaque nouvelle exécution terminée.
@MainActor
struct TaskHistoryTab: View {
    let model: AgentModel
    let taskID: UUID?
    let reloadKey: UUID?
    let text: CardText
    @State private var records: [RunRecord] = []
    @State private var selected: UUID?
    @State private var logRecord: RunRecord?

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                HistoryTableBody(rows: records, selection: selected, text: text, localizer: l) { id in
                    if selected == id { logRecord = records.first { $0.id == id } } else { selected = id }
                }
            }
            HStack {
                Button(l.text("detail.history.log")) { logRecord = records.first { $0.id == selected } }.disabled(selected == nil)
                Spacer()
                if let taskID {
                    Button(l.text("detail.history.clear")) {
                        Task { await model.clearHistory(taskID: taskID); records = await model.taskHistory(for: taskID) }
                    }
                    .disabled(records.isEmpty)
                }
            }
            .controlSize(.small)
        }
        .task(id: "\(taskID?.uuidString ?? "autres")-\(reloadKey?.uuidString ?? "")") {
            records = await model.taskHistory(for: taskID)
        }
        .sheet(item: $logRecord) { record in
            RunLogSheet(model: model, record: record, localizer: l) { logRecord = nil }
        }
    }
}

/// L'essentiel d'une tâche, modifiable sur place ; « Modifier… » ouvre l'éditeur complet.
@MainActor
struct TaskSettingsTab: View {
    let model: AgentModel
    let task: SyncTask
    let localizer: Localizer
    let onEdit: (SyncTask) -> Void
    @State private var settings: QuickSettings
    @State private var saving = false

    init(model: AgentModel, task: SyncTask, localizer: Localizer, onEdit: @escaping (SyncTask) -> Void) {
        self.model = model
        self.task = task
        self.localizer = localizer
        self.onEdit = onEdit
        _settings = State(initialValue: QuickSettings(task: task))
    }

    func openEditor() { onEdit(task) }

    private var l: Localizer { localizer }

    var body: some View {
        Form {
            if let trigger = settings.driveTrigger {
                Picker(l.text("detail.settings.trigger"), selection: Binding(
                    get: { if case .atMostEveryDays = trigger { return 1 } else { return 0 } },
                    set: { settings.driveTrigger = $0 == 0 ? .everyConnection : .atMostEveryDays(7) }
                )) {
                    Text(l.text("detail.settings.trigger.each")).tag(0)
                    Text(l.text("detail.settings.trigger.days")).tag(1)
                }
                if case .atMostEveryDays(let days) = trigger {
                    Stepper(l.format("detail.settings.days", days), value: Binding(
                        get: { days }, set: { settings.driveTrigger = .atMostEveryDays(max(1, $0)) }), in: 1...90)
                }
            } else {
                ScheduleField(schedule: $settings.schedule, localizer: l)
            }
            Toggle(l.text("detail.settings.enabled"), isOn: $settings.isEnabled)
            Toggle(l.text("detail.settings.ac"), isOn: $settings.requiresACPower)
            Toggle(l.text("detail.settings.hours"), isOn: Binding(
                get: { settings.allowedHours != nil },
                set: { settings.allowedHours = $0 ? (settings.allowedHours ?? HourRange(start: 22, end: 7)) : nil }))
            if let hours = settings.allowedHours {
                HStack {
                    Stepper(l.format("detail.settings.from", hours.start), value: Binding(
                        get: { hours.start }, set: { settings.allowedHours?.start = ($0 + 24) % 24 }))
                    Stepper(l.format("detail.settings.to", hours.end), value: Binding(
                        get: { hours.end }, set: { settings.allowedHours?.end = ($0 + 24) % 24 }))
                }
            }
            HStack {
                Button(l.text("detail.settings.edit")) { openEditor() }
                Spacer()
                Button(l.text("detail.settings.save")) {
                    saving = true
                    Task { _ = await model.saveTask(settings.apply(to: task)); saving = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || settings == QuickSettings(task: task))
            }
        }
        .formStyle(.grouped)
    }
}

/// Horaire simple : à la main, chaque jour à…, toutes les N minutes ; les autres (jours ouvrés, dès que disponible)
/// se changent dans l'éditeur complet.
@MainActor
struct ScheduleField: View {
    @Binding var schedule: Schedule
    let localizer: Localizer

    var body: some View {
        Picker(localizer.text("detail.settings.schedule"), selection: Binding(
            get: { kind },
            set: { kind in
                switch kind {
                case 0: schedule = .manual
                case 1: schedule = .daily(hour: 21, minute: 0)
                default: schedule = .everyMinutes(60)
                }
            })) {
            Text(localizer.text("detail.settings.manual")).tag(0)
            Text(localizer.text("detail.settings.daily")).tag(1)
            Text(localizer.text("detail.settings.every")).tag(2)
            if kind == 3 { Text(localizer.text("detail.settings.other")).tag(3) }
        }
        switch schedule {
        case .daily(let hour, let minute):
            HStack {
                Stepper(String(format: "%02d h", hour), value: Binding(get: { hour }, set: { schedule = .daily(hour: ($0 + 24) % 24, minute: minute) }))
                Stepper(String(format: "%02d min", minute), value: Binding(get: { minute }, set: { schedule = .daily(hour: hour, minute: ($0 + 60) % 60) }), step: 5)
            }
        case .everyMinutes(let minutes):
            Stepper(localizer.format("detail.settings.minutes", minutes), value: Binding(get: { minutes }, set: { schedule = .everyMinutes(max(5, $0)) }), step: 5)
        default: EmptyView()
        }
    }

    private var kind: Int {
        switch schedule {
        case .manual: return 0
        case .daily: return 1
        case .everyMinutes: return 2
        case .weekdays, .whenAvailable: return 3
        }
    }
}

/// Fin du journal de l'exécution en cours, ou de la dernière.
@MainActor
struct TaskLogTab: View {
    let model: AgentModel
    let record: RunRecord?
    let localizer: Localizer
    @State private var outcome: LogOutcome?

    var body: some View {
        ScrollView { RunLogContent(outcome: record == nil ? .missing : outcome, localizer: localizer) }
            .task(id: record?.id) {
                if let record { outcome = await model.runLog(record.id) }
            }
    }
}
