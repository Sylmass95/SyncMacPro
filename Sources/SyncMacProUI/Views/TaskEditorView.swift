import SwiftUI
import SyncKit

/// Éditeur de tâche en 5 étapes, présenté en feuille.
@MainActor
public struct TaskEditorView: View {
    let model: AgentModel
    let isNew: Bool
    let localizer: Localizer
    let resolver: EndpointResolver
    let onClose: () -> Void
    @State private var draft: TaskDraft
    @State private var step: EditorStep = .endpoints
    @State private var simulation: SimulationState = .idle
    @State private var saveError: String?
    @State private var saving = false
    /// La version du brouillon simulée : un résultat ne vaut que pour elle.
    @State private var simulatedKey: SyncTask?
    @State private var wizard: WizardModel?
    /// Connexions connues à l'ouverture de l'assistant : la nouvelle est choisie d'office à sa fermeture.
    @State private var remotesBefore: Set<String> = []

    public init(
        model: AgentModel, draft: TaskDraft, isNew: Bool, localizer: Localizer = .system,
        resolver: EndpointResolver = .system, onClose: @escaping () -> Void
    ) {
        self.model = model
        self.isNew = isNew
        self.localizer = localizer
        self.resolver = resolver
        self.onClose = onClose
        _draft = State(initialValue: draft)
    }

    private var text: TaskSummaryText { TaskSummaryText(localizer: localizer) }
    private var offline: Bool { model.connection != .connected }
    private var stepProblems: [TaskProblem] { draft.problems(for: step, resolver: resolver) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                EditorStepContent(
                    draft: $draft, step: step, text: text, resolver: resolver, simulation: simulation,
                    saveError: saveError, offline: offline,
                    onSimulate: { Task { await simulate() } },
                    onCancelSimulation: { Task { await model.cancelSimulation(draft.id) } },
                    remotes: RemoteContext(
                        remotes: model.remotes,
                        onAdd: {
                            remotesBefore = Set(model.remotes.map(\.name))
                            wizard = WizardModel(model: model, localizer: localizer)
                        },
                        browse: { remote, path in await model.remoteFolders(remote: remote, path: path) }
                    )
                )
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 620)
        .background(GlassBackdrop())
        .glassThemed()
        .onChange(of: draft) { _, _ in
            // Une simulation ne vaut que pour la version simulée (un renommage ne compte pas).
            if let key = simulatedKey, draft.simulationKey(resolver: resolver) != key {
                cancelRunningSimulation()
                simulation = .idle
                simulatedKey = nil
            }
            saveError = nil
        }
        // Fermer l'éditeur (Annuler, Échap, enregistrement) arrête la simulation en cours.
        .onDisappear { cancelRunningSimulation() }
        .task { await model.reloadRemotes() }
        .sheet(item: Binding(get: { wizard.map(WizardSession.init) }, set: { if $0 == nil { wizard = nil } })) { session in
            ConnectionWizardView(wizard: session.wizard, localizer: localizer) {
                wizard = nil
                Task { await adoptNewRemote() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? localizer.text("editor.title.new") : localizer.text("editor.title.edit")).font(.title2.bold())
            HStack(spacing: 6) {
                ForEach(EditorStep.allCases, id: \.self) { item in
                    Button { go(to: item) } label: {
                        Text("\(item.rawValue + 1). \(text.stepTitle(item))")
                            .font(.callout.weight(item == step ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(item == step ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!reachable(item))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(localizer.text("editor.cancel"), action: onClose).keyboardShortcut(.cancelAction)
            if offline {
                Text(localizer.text("editor.offline")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let problem = stepProblems.first {
                Text(text.problem(problem)).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if step != .endpoints {
                Button(localizer.text("editor.back")) { go(to: EditorStep(rawValue: step.rawValue - 1) ?? .endpoints) }
            }
            if step == .summary {
                Button(saving ? localizer.text("editor.saving") : localizer.text("editor.save")) {
                    Task { await save() }
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(saving || offline || !draft.problems(resolver: resolver).isEmpty)
            } else {
                Button(localizer.text("editor.next")) { go(to: EditorStep(rawValue: step.rawValue + 1) ?? .summary) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!stepProblems.isEmpty)
            }
        }
        .padding(14)
    }

    /// Une étape est accessible quand toutes les précédentes sont correctes.
    private func reachable(_ target: EditorStep) -> Bool {
        EditorStep.allCases.filter { $0.rawValue < target.rawValue }
            .allSatisfy { draft.problems(for: $0, resolver: resolver).isEmpty }
    }

    private func go(to target: EditorStep) {
        guard reachable(target) else { return }
        if target == .summary { draft.fillNameIfNeeded() }
        step = target
    }

    private func save() async {
        saving = true
        let message = await model.saveTask(draft.task(resolver: resolver))
        saving = false
        if let message { saveError = message } else { onClose() }
    }

    private func simulate() async {
        let key = draft.simulationKey(resolver: resolver)
        simulatedKey = key
        simulation = .running
        let outcome = await model.simulate(draft.task(resolver: resolver))
        // Le brouillon a changé pendant la simulation : ce résultat ne le décrit plus.
        guard draft.simulationKey(resolver: resolver) == key else { return }
        simulation = .finished(outcome)
    }

    /// Après l'assistant : la nouvelle connexion va au côté « service en ligne » encore vide (destination d'abord).
    private func adoptNewRemote() async {
        await model.reloadRemotes()
        let added = model.remotes.map(\.name).filter { !remotesBefore.contains($0) }
        guard added.count == 1, let name = added.first else { return }
        if draft.destination.kind == .cloud && draft.destination.remote.isEmpty {
            draft.destination.remote = name
        } else if draft.source.kind == .cloud && draft.source.remote.isEmpty {
            draft.source.remote = name
        }
    }

    private func cancelRunningSimulation() {
        guard case .running = simulation else { return }
        let id = draft.id
        Task { await model.cancelSimulation(id) }
    }
}
