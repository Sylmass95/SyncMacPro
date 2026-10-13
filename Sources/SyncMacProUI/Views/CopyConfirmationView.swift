import SwiftUI
import SyncKit

/// Le contenu de la confirmation, sans défilement (rendu par les tests).
@MainActor
struct CopyConfirmationContent: View {
    let tasks: [SyncTask]
    let isSync: Bool
    let simulation: SimulationState
    let error: String?
    @Binding var acceptDeletions: Bool
    let offline: Bool
    let localizer: Localizer

    private var text: TaskSummaryText { TaskSummaryText(localizer: localizer) }

    /// Après une simulation qui annonce des suppressions, une synchronisation peut les accepter d'avance
    /// (le garde-fou bloquerait sinon une exécution qui n'existe plus ensuite pour être validée).
    static func offersDeletionApproval(isSync: Bool, simulation: SimulationState) -> Bool {
        guard isSync, case .finished(.finished(let result)) = simulation else { return false }
        return result.deletions > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.text(isSync ? "confirm.title.sync" : "confirm.title.copy")).font(.title3.bold())
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.headline)
                    Text(text.sentence(for: task)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(Set(tasks.flatMap { text.warnings(for: $0) })).sorted(), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(Set(tasks.flatMap { TaskValidator.problems(in: $0) }.map { text.problem($0) })).sorted(), id: \.self) { problem in
                Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            simulationSection
            if Self.offersDeletionApproval(isSync: isSync, simulation: simulation) {
                Toggle(localizer.text("confirm.acceptDeletions"), isOn: $acceptDeletions)
            }
            if let error {
                Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if offline {
                Text(localizer.text("confirm.offline")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var simulationSection: some View {
        switch simulation {
        case .idle:
            Text(localizer.text("confirm.simulate.help")).font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack { ProgressView().controlSize(.small); Text(localizer.text("editor.simulating")) }
        case .finished(.finished(let result)):
            Label(text.simulation(result), systemImage: result.deletions > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.deletions > 0 ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
        case .finished(.failed(let message)):
            Label(localizer.format("simulation.failed", message), systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Feuille ouverte avant toute copie ou synchronisation : résumé, avertissements, Simuler, Lancer.
@MainActor
struct CopyConfirmationView: View {
    let model: AgentModel
    let session: CopySession
    let localizer: Localizer
    let onClose: () -> Void
    @State private var simulation: SimulationState = .idle
    @State private var acceptDeletions = false
    @State private var error: String?
    @State private var launching = false
    @State private var simulatedIDs: [UUID] = []

    private var isSync: Bool {
        if case .sync = session.request { return true }
        return false
    }

    private var tasks: [SyncTask] {
        OneOffPlanner.tasks(for: session.request, acceptDeletions: acceptDeletions, localizer: localizer)
    }

    private var offline: Bool { model.connection != .connected }
    /// Une demande refusée (dossiers imbriqués…) ne se simule ni ne se lance.
    private var invalid: Bool { tasks.contains { !TaskValidator.problems(in: $0).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                CopyConfirmationContent(
                    tasks: tasks, isSync: isSync, simulation: simulation, error: error,
                    acceptDeletions: $acceptDeletions, offline: offline, localizer: localizer
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(localizer.text("confirm.cancel"), role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                if case .running = simulation {
                    Button(localizer.text("editor.simulate.cancel")) { cancelSimulations() }
                } else {
                    Button(localizer.text("confirm.simulate")) { Task { await simulate() } }.disabled(offline || invalid)
                }
                Button(localizer.text("confirm.launch")) { Task { await launch() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(offline || launching || invalid)
            }
        }
        .padding(20)
        .frame(width: 540, height: 380)
        .task { if session.simulateAtOnce && !invalid { await simulate() } }
        .onDisappear { cancelSimulations() }
    }

    private func simulate() async {
        error = nil
        simulation = .running
        let planned = tasks
        simulatedIDs = planned.map(\.id)
        var outcomes: [SimulationOutcome] = []
        for task in planned {
            outcomes.append(await model.simulate(task))
            guard case .running = simulation else { return }
        }
        simulatedIDs = []
        simulation = .finished(OneOffPlanner.combine(outcomes))
    }

    private func cancelSimulations() {
        guard case .running = simulation else { return }
        let ids = simulatedIDs
        simulation = .idle
        simulatedIDs = []
        Task { for id in ids { await model.cancelSimulation(id) } }
    }

    private func launch() async {
        launching = true
        defer { launching = false }
        if let refusal = await model.runOnce(tasks) {
            error = refusal
        } else {
            close()
        }
    }

    private func close() {
        cancelSimulations()
        onClose()
    }
}
