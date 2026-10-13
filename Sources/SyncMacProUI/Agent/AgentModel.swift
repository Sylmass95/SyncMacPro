import Foundation
import Observation
import os
import SyncKit

/// L'état de l'agent tel que l'app le montre : connexion, tâches, avancement, historique.
/// La boucle de connexion se rétablit seule quand l'agent redémarre.
@MainActor
@Observable
public final class AgentModel {
    public struct Timing: Sendable {
        public var debounce: TimeInterval = 0.25
        public var safetyRefresh: TimeInterval = 30
        public var backoff: [TimeInterval] = [1, 2, 4, 8, 15]
        public var versionRetry: TimeInterval = 60
        public init() {}
    }

    public private(set) var connection: ConnectionState = .connecting
    public private(set) var status: AgentStatus?
    public private(set) var tasks: [UUID: SyncTask] = [:]
    public private(set) var progress: [UUID: ProgressInfo] = [:]
    public private(set) var history: [RunRecord] = []
    public private(set) var historyError: String?
    public private(set) var busyTasks: Set<UUID> = []
    public private(set) var globalPauseBusy = false
    public var alertMessage: String?

    @ObservationIgnored private let agent: AgentConnecting
    @ObservationIgnored private let sleeper: Sleeping
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var safety: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var watching: (any AgentWatching)?
    @ObservationIgnored private var currentEnd: EndSignal?
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var hasConnected = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private static let log = Logger(subsystem: "com.sylvain.syncmacpro", category: "agent")

    public init(agent: AgentConnecting, sleeper: Sleeping = RealSleeper(), timing: Timing = Timing()) {
        self.agent = agent
        self.sleeper = sleeper
        self.timing = timing
    }

    /// Modèle pré-rempli pour les aperçus et les captures : aucune connexion n'est ouverte.
    public static func preview(
        connection: ConnectionState = .connected, status: AgentStatus?, tasks: [SyncTask] = [],
        progress: [UUID: ProgressInfo] = [:], history: [RunRecord] = [], historyError: String? = nil
    ) -> AgentModel {
        let model = AgentModel(agent: UnavailableAgent())
        model.connection = connection
        model.status = status
        model.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        model.progress = progress
        model.history = history
        model.historyError = historyError
        return model
    }

    // MARK: cycle de vie

    public func start() {
        guard loop == nil else { return }
        generation += 1
        let current = generation
        loop = Task { [weak self] in await self?.runLoop(generation: current) }
    }

    /// « Réessayer » : repart tout de suite au lieu d'attendre la fin de l'attente.
    public func restart() {
        shutdown()
        failures = 0
        start()
    }

    public func shutdown() {
        // Tout ce qu'une boucle précédente fera encore (un appel XPC n'est pas annulable) sera ignoré.
        generation += 1
        loop?.cancel()
        loop = nil
        safety?.cancel()
        safety = nil
        debounce?.cancel()
        debounce = nil
        currentEnd?.fire()
        currentEnd = nil
        watching?.cancel()
        watching = nil
    }

    // MARK: boucle de connexion

    private func setConnection(_ state: ConnectionState) {
        guard connection != state else { return }
        connection = state
        Self.log.notice("connexion : \(String(describing: state), privacy: .public)")
    }

    /// Vrai tant que la boucle `generation` est celle en service : une boucle remplacée ne touche plus à rien.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func runLoop(generation: Int) async {
        while isCurrent(generation) {
            let delay: TimeInterval
            do {
                try await session(generation: generation)
                guard isCurrent(generation) else { return }
                // La session s'est terminée (l'agent a disparu) : on retente vite.
                failures = 1
                setConnection(.reconnecting(attempt: 1))
                delay = timing.backoff[0]
            } catch {
                guard isCurrent(generation) else { return }
                if case AgentClientError.agent(.versionMismatch(let agentVersion, _))? = error as? AgentClientError {
                    setConnection(.versionMismatch(agent: agentVersion))
                    delay = timing.versionRetry
                } else {
                    delay = registerFailure()
                }
            }
            try? await sleeper.sleep(seconds: delay)
        }
    }

    /// Une fois le plafond d'attente atteint, l'agent est déclaré injoignable : le bandeau propose alors
    /// Installer et Réessayer, au lieu d'une « reconnexion » sans fin.
    private func registerFailure() -> TimeInterval {
        failures += 1
        let stillTrying = hasConnected && failures < timing.backoff.count
        setConnection(stillTrying ? .reconnecting(attempt: failures) : .unreachable)
        return timing.backoff[min(failures - 1, timing.backoff.count - 1)]
    }

    /// Se connecte, s'abonne, puis attend la fin de la connexion. L'abonnement et la relecture de sécurité
    /// restent propres à cette session : une session remplacée ne peut ni écraser ni annuler ceux de la suivante.
    private func session(generation: Int) async throws {
        let first = try await agent.status()
        let list = try await agent.listTasks()
        guard isCurrent(generation) else { throw CancellationError() }
        failures = 0
        hasConnected = true
        apply(status: first, tasks: list)
        setConnection(.connected)

        let ended = EndSignal()
        currentEnd = ended
        // Boîte à référence faible plutôt que `[weak self]` : Swift 5.10 refuse un `weak self` capturé dans une
        // closure concurrente imbriquée (« reference to captured var 'self' »).
        let target = WeakModel(self)
        let watch = try await agent.startWatching(
            onEvent: { event in Task { @MainActor in target.value?.handle(event) } },
            onEnd: { ended.fire() }
        )
        guard isCurrent(generation) else {
            watch.cancel()
            throw CancellationError()
        }
        watching = watch
        await reloadHistory()
        guard isCurrent(generation) else {
            watch.cancel()
            throw CancellationError()
        }
        let refresher = makeSafetyRefresh()
        safety = refresher
        await ended.wait()
        refresher.cancel()
        watch.cancel()
        if isCurrent(generation) {
            safety = nil
            watching = nil
            currentEnd = nil
        }
    }

    // MARK: événements

    private func handle(_ event: AgentEvent) {
        switch event {
        case .progress(let id, let info):
            progress[id] = info
        case .taskFinished(let id, _, _):
            progress[id] = nil
            historyDirty = true
            scheduleRefresh()
        case .taskStarted, .stateChanged:
            scheduleRefresh()
        }
    }

    /// Une rafale d'événements ne fait qu'une relecture.
    private func scheduleRefresh() {
        guard debounce == nil else { return }
        debounce = Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper.sleep(seconds: self.timing.debounce)
            if Task.isCancelled { return }
            await self.flushRefresh()
        }
    }

    private func flushRefresh() async {
        debounce = nil
        let includeHistory = historyDirty
        historyDirty = false
        await refreshNow()
        if includeHistory { await reloadHistory() }
    }

    private func makeSafetyRefresh() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.sleeper.sleep(seconds: self.timing.safetyRefresh)
                if Task.isCancelled { return }
                await self.refreshNow()
            }
        }
    }

    // MARK: lecture

    public func refreshNow() async {
        guard let latest = try? await agent.status() else { return }
        let list = (try? await agent.listTasks()) ?? Array(tasks.values)
        apply(status: latest, tasks: list)
    }

    public func reloadHistory() async {
        do {
            history = try await agent.history(taskID: nil, limit: 500)
            historyError = nil
        } catch {
            historyError = Self.describe(error)
        }
    }

    private func apply(status new: AgentStatus, tasks list: [SyncTask]) {
        status = new
        tasks = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for info in new.tasks {
            if let current = info.progress {
                progress[info.id] = current
            } else if info.state != .running && info.state != .paused {
                progress[info.id] = nil
            }
        }
    }

    // MARK: actions

    public func runNow(_ id: UUID) async { await act(on: id) { try await $0.perform(.runNow(id)) } }
    public func pause(_ id: UUID) async { await act(on: id) { try await $0.perform(.pause(id)) } }
    public func resume(_ id: UUID) async { await act(on: id) { try await $0.perform(.resume(id)) } }
    public func stop(_ id: UUID) async { await act(on: id) { try await $0.perform(.stop(id)) } }
    public func approve(_ id: UUID) async { await act(on: id) { try await $0.perform(.approveDeletion(id)) } }

    public func setGlobalPause(_ paused: Bool) async {
        globalPauseBusy = true
        defer { globalPauseBusy = false }
        await act(on: nil) { try await $0.perform(.setGlobalPause(paused)) }
    }

    /// On attend la réponse de l'agent, puis on relit l'état : l'interface n'affiche jamais l'effet d'avance.
    private func act(on id: UUID?, _ body: (AgentConnecting) async throws -> Void) async {
        if let id { busyTasks.insert(id) }
        defer { if let id { busyTasks.remove(id) } }
        do {
            try await body(agent)
            await refreshNow()
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    // MARK: tâches

    /// `nil` si l'agent a enregistré la tâche ; sinon le message, affiché dans l'éditeur (qui reste ouvert).
    public func saveTask(_ task: SyncTask) async -> String? {
        do {
            try await agent.perform(.saveTask(task))
            await refreshNow()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard var task = tasks[id], task.isEnabled != enabled else { return }
        task.isEnabled = enabled
        if let message = await saveTask(task) { alertMessage = message }
    }

    public func removeTask(_ id: UUID) async {
        await act(on: id) { try await $0.perform(.removeTask(id)) }
    }

    public func simulate(_ task: SyncTask) async -> SimulationOutcome {
        do { return .finished(try await agent.simulate(task)) } catch { return .failed(Self.describe(error)) }
    }

    public func cancelSimulation(_ id: UUID) async {
        try? await agent.perform(.cancelSimulation(id))
    }

    public func runLog(_ runID: UUID) async -> LogOutcome {
        do {
            return .loaded(try await agent.runLog(runID: runID))
        } catch AgentClientError.agent(.unknownRun) {
            return .missing
        } catch {
            return .failed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

final class WeakModel: @unchecked Sendable {
    weak var value: AgentModel?
    init(_ value: AgentModel) { self.value = value }
}

/// Signal de fin de connexion : `wait()` reprend dès que `fire()` a été appelé, avant ou après.
final class EndSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        fired = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
