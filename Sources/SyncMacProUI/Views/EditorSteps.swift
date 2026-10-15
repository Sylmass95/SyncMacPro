import AppKit
import SwiftUI
import SyncKit

public enum SimulationState: Equatable, Sendable {
    case idle
    case running
    case finished(SimulationOutcome)
}

/// Le contenu d'une étape, sans défilement (rendu par les tests).
@MainActor
struct EditorStepContent: View {
    @Binding var draft: TaskDraft
    let step: EditorStep
    let text: TaskSummaryText
    let resolver: EndpointResolver
    let simulation: SimulationState
    let saveError: String?
    let offline: Bool
    let onSimulate: () -> Void
    let onCancelSimulation: () -> Void
    var remotes: RemoteContext = .none

    var body: some View {
        switch step {
        case .endpoints: EndpointsStepView(draft: $draft, localizer: text.localizer, remotes: remotes)
        case .mode: ModeStepView(draft: $draft, text: text)
        case .options: OptionsStepView(draft: $draft, text: text)
        case .schedule: ScheduleStepView(draft: $draft, text: text, resolver: resolver)
        case .summary:
            SummaryStepView(
                draft: $draft, text: text, resolver: resolver, simulation: simulation, saveError: saveError,
                offline: offline, onSimulate: onSimulate, onCancel: onCancelSimulation
            )
        }
    }
}

// MARK: 1. source et destination

@MainActor
struct EndpointsStepView: View {
    @Binding var draft: TaskDraft
    let localizer: Localizer
    var remotes: RemoteContext = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SideEditor(title: localizer.text("editor.source"), side: $draft.source, localizer: localizer, remotes: remotes)
            SideEditor(title: localizer.text("editor.destination"), side: $draft.destination, localizer: localizer, remotes: remotes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct SideEditor: View {
    let title: String
    @Binding var side: SideDraft
    let localizer: Localizer
    var remotes: RemoteContext = .none
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker("", selection: $side.kind) {
                Text(localizer.text("editor.side.folder")).tag(SideKind.folder)
                Text(localizer.text("editor.side.cloud")).tag(SideKind.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            if side.kind == .folder {
                HStack {
                    TextField(localizer.text("editor.path"), text: $side.path).textFieldStyle(.roundedBorder)
                    Button(localizer.text("editor.choose")) {
                        if let path = FolderPicker.choose() { side.path = path }
                    }
                }
            } else {
                HStack {
                    Picker(localizer.text("editor.remote"), selection: $side.remote) {
                        if side.remote.isEmpty { Text(localizer.text("remote.pick")).tag("") }
                        ForEach(remotes.remotes) { remote in Text(remote.name).tag(remote.name) }
                        // Une connexion inconnue (supprimée, ou tapée avant 4) reste affichée telle quelle.
                        if !side.remote.isEmpty && !remotes.remotes.contains(where: { $0.name == side.remote }) {
                            Text(side.remote).tag(side.remote)
                        }
                    }
                    .frame(width: 220)
                    Button(localizer.text("remote.add"), action: remotes.onAdd).disabled(remotes.offline)
                }
                HStack {
                    TextField(localizer.text("editor.path"), text: $side.path).textFieldStyle(.roundedBorder)
                    Button(localizer.text("editor.choose")) { browsing = true }.disabled(side.remote.isEmpty)
                }
                Text(localizer.text("editor.remote.help")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $browsing) {
            RemoteFolderPicker(
                remote: side.remote, startPath: side.path, localizer: localizer, browse: remotes.browse,
                onChoose: { side.path = $0; browsing = false }, onCancel: { browsing = false }
            )
        }
    }
}

enum FolderPicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: 2. mode

@MainActor
struct ModeStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
            ForEach(SyncMode.allCases, id: \.self) { mode in
                ModeCard(
                    title: text.modeTitle(mode), description: text.modeDescription(mode),
                    warning: text.modeWarning(mode), note: text.modeNote(mode), selected: draft.mode == mode
                )
                .onTapGesture { draft.mode = mode }
            }
        }
    }
}

@MainActor
struct ModeCard: View {
    let title: String
    let description: String
    let warning: String?
    let note: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .glassCard(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: 3. options

@MainActor
struct OptionsStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText

    private var l: Localizer { text.localizer }
    private var touchesCloud: Bool { draft.source.kind == .cloud || draft.destination.kind == .cloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(l.text("editor.options.transfer")) {
                Text(l.text("editor.options.excludes")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.excludesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                field(l.text("editor.options.bandwidth"), text: $draft.bandwidthText)
                Toggle(l.text("editor.options.verify"), isOn: $draft.options.verifyAfterCopy)
                if touchesCloud { field(l.text("editor.options.quota"), text: $draft.maxTransferText) }
            }
            if draft.mode.deletesData || draft.mode == .versioned {
                group(l.text("editor.options.safety")) {
                    Stepper(
                        l.format("editor.options.threshold", draft.options.deleteThresholdPercent),
                        value: $draft.options.deleteThresholdPercent, in: 1...100, step: 5
                    )
                    if draft.mode == .mirror { field(l.text("editor.options.archive"), text: $draft.options.archiveFolder) }
                    if draft.mode == .versioned { field(l.text("editor.options.retention"), text: $draft.retentionText) }
                }
            }
            group(l.text("editor.options.conditions")) {
                Toggle(l.text("editor.options.ac"), isOn: $draft.conditions.requiresACPower)
                Toggle(l.text("editor.options.network"), isOn: $draft.conditions.requiresNetwork)
                Toggle(l.text("editor.options.hours"), isOn: hoursEnabled)
                if let range = draft.conditions.allowedHours {
                    HStack(spacing: 16) {
                        Stepper(l.format("editor.options.hours.start", range.start), value: hour(\.start), in: 0...23)
                        Stepper(l.format("editor.options.hours.end", range.end), value: hour(\.end), in: 0...23)
                    }
                }
            }
            group(l.text("editor.options.notifications")) {
                Picker("", selection: $draft.notifications) {
                    ForEach(NotificationPolicy.allCases, id: \.self) { Text(text.notification($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var hoursEnabled: Binding<Bool> {
        Binding(
            get: { draft.conditions.allowedHours != nil },
            set: { draft.conditions.allowedHours = $0 ? HourRange(start: 22, end: 6) : nil }
        )
    }

    private func hour(_ keyPath: WritableKeyPath<HourRange, Int>) -> Binding<Int> {
        Binding(
            get: { draft.conditions.allowedHours?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var range = draft.conditions.allowedHours else { return }
                range[keyPath: keyPath] = value
                draft.conditions.allowedHours = range
            }
        )
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text).textFieldStyle(.roundedBorder).frame(width: 160)
        }
    }
}

// MARK: 4. planification

@MainActor
struct ScheduleStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText
    let resolver: EndpointResolver

    private var l: Localizer { text.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Liée à un disque : la sauvegarde part au branchement, la planification n'a plus de sens.
            if draft.removable?.drive == nil {
                scheduleChoice
                Text(l.format("editor.next.run", text.nextRun(for: draft.task(resolver: resolver))))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let removable = draft.removable {
                RemovableDriveSection(
                    drive: Binding(get: { draft.removable ?? removable }, set: { draft.removable = $0 }), localizer: l
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var scheduleChoice: some View {
        Picker(l.text("editor.schedule.kind"), selection: $draft.scheduleDraft.kind) {
            ForEach(ScheduleKind.allCases, id: \.self) { Text(text.scheduleKind($0)).tag($0) }
        }
        .pickerStyle(.radioGroup)
        switch draft.scheduleDraft.kind {
        case .daily:
            timePicker
        case .weekdays:
            weekdayPicker
            timePicker
        case .everyMinutes:
            Stepper(
                l.format("editor.schedule.every", draft.scheduleDraft.interval),
                value: $draft.scheduleDraft.interval, in: 1...1440, step: 5
            )
        case .manual, .whenAvailable:
            EmptyView()
        }
    }

    private var timePicker: some View {
        DatePicker(l.text("editor.schedule.time"), selection: time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .frame(maxWidth: 240)
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                Toggle(isOn: weekday(day)) { Text(l.text("weekday.\(day)")) }.toggleStyle(.button)
            }
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                text.calendar.date(
                    bySettingHour: draft.scheduleDraft.hour, minute: draft.scheduleDraft.minute, second: 0, of: text.now
                ) ?? text.now
            },
            set: { date in
                let parts = text.calendar.dateComponents([.hour, .minute], from: date)
                draft.scheduleDraft.hour = parts.hour ?? 0
                draft.scheduleDraft.minute = parts.minute ?? 0
            }
        )
    }

    private func weekday(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { draft.scheduleDraft.days.contains(day) },
            set: { on in
                if on { draft.scheduleDraft.days.insert(day) } else { draft.scheduleDraft.days.remove(day) }
            }
        )
    }
}

/// Section « Disque amovible » : lien au disque, déclenchement, délai de reprise, éjection.
@MainActor
struct RemovableDriveSection: View {
    @Binding var drive: RemovableDraft
    let localizer: Localizer

    private var l: Localizer { localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(l.text("editor.drive.title"), systemImage: "externaldrive").font(.headline)
            if let uuid = drive.volumeUUID {
                Text(l.format("editor.drive.identity", drive.volumeName, String(uuid.prefix(8))))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(l.text("editor.drive.link"), isOn: $drive.linked)
                if drive.linked {
                    Picker(l.text("editor.drive.trigger"), selection: $drive.everyConnection) {
                        Text(l.text("editor.drive.trigger.every")).tag(true)
                        Text(l.text("editor.drive.trigger.days")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if !drive.everyConnection {
                        Stepper(l.format("editor.drive.days", drive.everyDays), value: $drive.everyDays, in: 1...365)
                    }
                    Stepper(l.format("editor.drive.window", drive.resumeWindowDays), value: $drive.resumeWindowDays, in: 1...30)
                    Picker(l.text("editor.drive.eject"), selection: $drive.eject) {
                        Text(l.text("editor.drive.eject.never")).tag(RemovableDrive.Eject.never)
                        Text(l.text("editor.drive.eject.button")).tag(RemovableDrive.Eject.button)
                        Text(l.text("editor.drive.eject.automatic")).tag(RemovableDrive.Eject.automatic)
                    }
                    .frame(maxWidth: 420)
                    Text(l.text("editor.drive.noschedule")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(l.format("editor.drive.nouuid", drive.volumeName)).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
    }
}

// MARK: 5. résumé

@MainActor
struct SummaryStepView: View {
    @Binding var draft: TaskDraft
    let text: TaskSummaryText
    let resolver: EndpointResolver
    let simulation: SimulationState
    let saveError: String?
    let offline: Bool
    let onSimulate: () -> Void
    let onCancel: () -> Void

    private var l: Localizer { text.localizer }

    var body: some View {
        let task = draft.task(resolver: resolver)
        VStack(alignment: .leading, spacing: 14) {
            TextField(l.text("editor.name"), text: $draft.name).textFieldStyle(.roundedBorder).font(.title3)
            Text(text.sentence(for: task)).font(.title3).fixedSize(horizontal: false, vertical: true)
            ForEach(text.warnings(for: task), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(l.format("editor.next.run", text.nextRun(for: task))).foregroundStyle(.secondary)
            Divider()
            simulationSection
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var simulationSection: some View {
        switch simulation {
        case .idle:
            Button(action: onSimulate) { Label(l.text("editor.simulate"), systemImage: "eye") }.disabled(offline)
            Text(l.text("editor.simulate.help")).font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text(l.text("editor.simulating"))
                Button(l.text("editor.simulate.cancel"), action: onCancel)
            }
        case .finished(let outcome):
            switch outcome {
            case .finished(let result):
                Label(
                    text.simulation(result),
                    systemImage: result.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(result.status == .succeeded ? Color.green : Color.red)
                if let warning = text.deletionsWarning(result) {
                    Label(warning, systemImage: "trash").foregroundStyle(.orange).font(.headline)
                }
            case .failed(let message):
                Label(l.format("simulation.failed", message), systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Button(l.text("editor.simulate.again"), action: onSimulate).disabled(offline)
        }
    }
}
