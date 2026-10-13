import Foundation

/// Cerveau de l'agent : décide quelles tâches lancer et quand, les exécute (2 à la fois au plus),
/// tient l'état et l'historique. Aucune horloge, aucun système en dur : tout est injecté, donc testable.
public actor AgentCore {
    struct QueuedRun {
        var id: UUID
        var dueDate: Date
        var overrideGuard = false
        /// Demandée par l'utilisateur (lancer, valider) : les conditions et l'horaire ne la concernent pas.
        var manual = false
    }

    struct Job {
        var task: SyncTask
        var runner: TaskRunning
        var record: RunRecord
        var paused = false
        var pausedByGlobal = false
        var lastProgressEmit: Date?
        var latest: ProgressInfo?
    }

    let configuration: AgentConfiguration
    let taskStore: TaskStore
    let stateStore: SchedulerStateStore
    let history: HistoryStore
    let clock: SchedulerClock
    let conditions: SystemConditions
    let notifier: AgentNotifier
    let activity: ActivityHolding
    let log: @Sendable (String) -> Void
    let makeRunner: @Sendable () -> TaskRunning

    var tasks: [SyncTask] = []
    var state: SchedulerState
    let stateRecovered: Bool
    var taskLoadError: String?
    var jobs: [UUID: Job] = [:]
    var jobTasks: [UUID: Task<Void, Never>] = [:]
    var queue: [QueuedRun] = []
    var waiting: [UUID: String] = [:]
    var holdUntil: Date?
    var lastTick: Date?
    var shuttingDown = false
    /// Vrai tant que l'assertion anti-veille est tenue.
    var activityHeld = false
    var observers: [UUID: @Sendable (AgentEvent) -> Void] = [:]

    public init(
        configuration: AgentConfiguration, taskStore: TaskStore, stateStore: SchedulerStateStore,
        history: HistoryStore, clock: SchedulerClock, conditions: SystemConditions,
        notifier: AgentNotifier, activity: ActivityHolding,
        log: @escaping @Sendable (String) -> Void = { _ in },
        makeRunner: @escaping @Sendable () -> TaskRunning
    ) {
        self.configuration = configuration
        self.taskStore = taskStore
        self.stateStore = stateStore
        self.history = history
        self.clock = clock
        self.conditions = conditions
        self.notifier = notifier
        self.activity = activity
        self.log = log
        self.makeRunner = makeRunner
        let loaded = stateStore.load()
        state = loaded.state
        stateRecovered = loaded.recovered
    }

    // MARK: démarrage

    /// À appeler une fois au lancement de l'agent.
    public func start() {
        let now = clock.now()
        loadTasks()
        _ = try? history.markRunningAsInterrupted(at: now)
        // Une tâche encore « en cours » dans l'état : l'agent a été tué en route. Elle sera rattrapée.
        for key in state.tasks.keys where state.tasks[key]?.runningSince != nil {
            state.tasks[key]?.runningSince = nil
            state.tasks[key]?.retryAt = now
        }
        if configuration.startupHold > 0 { holdUntil = now.addingTimeInterval(configuration.startupHold) }
        persist()
    }

    /// Relit `tasks.json`. En cas d'erreur de lecture, on garde la liste précédente et on le signale.
    public func reloadTasks() {
        loadTasks()
        persist()
        emit(.stateChanged)
    }

    func loadTasks() {
        do {
            tasks = try taskStore.load()
            taskLoadError = nil
        } catch {
            taskLoadError = "\(error)"
            log("tasks.json illisible : \(error)")
            return
        }
        let now = clock.now()
        for task in tasks where state.tasks[task.id.uuidString] == nil {
            state.tasks[task.id.uuidString] = TaskScheduleState(firstSeen: now)
        }
        let known = Set(tasks.map { $0.id.uuidString })
        state.tasks = state.tasks.filter { key, _ in
            known.contains(key) || UUID(uuidString: key).map { jobs[$0] != nil } == true
        }
    }

    // MARK: évaluation

    /// Appelée chaque minute et à chaque réveil par le programme de l'agent.
    public func tick() {
        let now = clock.now()
        defer { lastTick = now }
        if let last = lastTick, now.timeIntervalSince(last) > configuration.wakeGap {
            holdUntil = now.addingTimeInterval(configuration.wakeHold)
        }
        purgeHistoryIfNeeded(now)
        guard !state.paused else { return }
        if let hold = holdUntil {
            if now < hold { return }
            holdUntil = nil
        }
        var changed = false
        for task in tasks where task.isEnabled {
            let key = task.id.uuidString
            guard jobs[task.id] == nil, !queue.contains(where: { $0.id == task.id }),
                  var entry = state.tasks[key], !entry.awaitingApproval else { continue }
            if task.schedule == .whenAvailable {
                let available = conditions.isReachable(task.source) && conditions.isReachable(task.destination)
                if entry.wasAvailable != available {
                    if available { entry.retryAt = now }
                    entry.wasAvailable = available
                    state.tasks[key] = entry
                    changed = true
                }
            }
            guard let due = dueDate(task, entry, now), due <= now else { continue }
            if let reason = unmetCondition(task, now: now) {
                waiting[task.id] = reason
                continue
            }
            waiting[task.id] = nil
            queue.append(QueuedRun(id: task.id, dueDate: due))
        }
        queue.sort { $0.dueDate < $1.dueDate }
        if changed { persist() }
        startQueued()
    }

    /// Échéance d'une tâche : le prochain essai s'il y en a un, sinon la prochaine occurrence de son horaire.
    func dueDate(_ task: SyncTask, _ entry: TaskScheduleState, _ now: Date) -> Date? {
        if let retry = entry.retryAt { return retry }
        let usesCalendar: Bool
        switch task.schedule {
        case .daily, .weekdays: usesCalendar = true
        case .everyMinutes, .manual, .whenAvailable: usesCalendar = false
        }
        let basis = entry.lastStart ?? (usesCalendar ? entry.firstSeen : nil)
        return Scheduler.nextDue(for: task.schedule, after: basis, now: now, calendar: clock.calendar)
    }

    func unmetCondition(_ task: SyncTask, now: Date) -> String? {
        let required = task.conditions
        if required.requiresACPower && !conditions.isOnACPower() { return "branchement secteur requis" }
        let needsNetwork = required.requiresNetwork || task.source.isCloud || task.destination.isCloud
        if needsNetwork && !conditions.isNetworkAvailable() { return "réseau indisponible" }
        if let range = required.allowedHours,
           !range.contains(hour: clock.calendar.component(.hour, from: now)) {
            return "hors de la plage horaire autorisée"
        }
        if !conditions.isReachable(task.source) { return "source inaccessible" }
        if !conditions.isReachable(task.destination) { return "destination inaccessible" }
        return nil
    }

    func purgeHistoryIfNeeded(_ now: Date) {
        if let last = state.lastPurge, now.timeIntervalSince(last) < 86400 { return }
        let limit = now.addingTimeInterval(-Double(configuration.historyRetentionDays) * 86400)
        _ = try? history.purge(finishedBefore: limit)
        state.lastPurge = now
        persist()
    }

    // MARK: exécution

    func startQueued() {
        guard !state.paused, !shuttingDown else { return }
        while jobs.count < configuration.maxParallel, !queue.isEmpty {
            let next = queue.removeFirst()
            guard let task = tasks.first(where: { $0.id == next.id }), jobs[task.id] == nil else { continue }
            // Une exécution planifiée peut attendre des heures derrière deux longues copies : on revérifie.
            if !next.manual {
                guard task.isEnabled else { continue }
                if let reason = unmetCondition(task, now: clock.now()) {
                    waiting[task.id] = reason
                    continue
                }
            }
            startJob(task, overrideGuard: next.overrideGuard)
        }
    }

    /// Tient l'assertion anti-veille tant qu'une copie avance ; une copie figée (pause) ne l'exige pas.
    func refreshActivity() {
        let needed = jobs.values.contains { !$0.paused }
        if needed && !activityHeld {
            activityHeld = true
            activity.begin()
        } else if !needed && activityHeld {
            activityHeld = false
            activity.end()
        }
    }

    func startJob(_ task: SyncTask, overrideGuard: Bool) {
        var runTask = task
        if overrideGuard { runTask.options.deleteThresholdPercent = 100 }
        let now = clock.now()
        let key = task.id.uuidString
        let engine = (try? EngineSelector.engine(for: runTask)) ?? .rsync
        let record = RunRecord(taskID: task.id, taskName: task.name, engine: engine, mode: task.mode, startedAt: now)
        try? history.save(record)

        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.lastStart = now
        entry.runningSince = now
        entry.retryAt = nil
        entry.awaitingApproval = false
        state.tasks[key] = entry
        persist()

        let runner = makeRunner()
        jobs[task.id] = Job(task: task, runner: runner, record: record)
        waiting[task.id] = nil
        refreshActivity()
        emit(.taskStarted(task.id))

        let id = task.id
        jobTasks[id] = Task.detached { [weak self] in
            let outcome: Result<RunResult, Error>
            do {
                outcome = .success(try await runner.run(runTask, dryRun: false) { update in
                    if case .snapshot(let snapshot) = update { Task { await self?.progress(id, snapshot) } }
                })
            } catch {
                outcome = .failure(error)
            }
            await self?.finish(id, outcome)
        }
    }

    func progress(_ id: UUID, _ snapshot: TransferSnapshot) {
        guard var job = jobs[id] else { return }
        let now = clock.now()
        let info = ProgressInfo(snapshot)
        job.latest = info
        // Au plus deux messages par seconde et par tâche : l'interface n'a pas besoin de plus.
        if let last = job.lastProgressEmit, now.timeIntervalSince(last) < 0.5 {
            jobs[id] = job
            return
        }
        job.lastProgressEmit = now
        jobs[id] = job
        emit(.progress(id, info))
    }

    func finish(_ id: UUID, _ outcome: Result<RunResult, Error>) {
        jobTasks[id] = nil
        guard var job = jobs.removeValue(forKey: id) else { return }
        let now = clock.now()
        var status: RunStatus
        let summary: RunSummary
        switch outcome {
        case .success(let result):
            status = result.status
            summary = result.summary
        case .failure(let error):
            status = .failed
            summary = RunSummary(
                errors: 1, durationSeconds: now.timeIntervalSince(job.record.startedAt), message: "\(error)"
            )
        }
        if shuttingDown && status == .stopped { status = .interrupted }

        job.record.status = status
        job.record.summary = summary
        job.record.finishedAt = now
        try? history.save(job.record)

        let key = id.uuidString
        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.runningSince = nil
        switch status {
        case .succeeded:
            entry.lastSuccess = now
            entry.attempts = 0
            entry.retryAt = nil
        case .failed, .quotaReached:
            entry.attempts += 1
            if entry.attempts < configuration.maxAttempts {
                entry.retryAt = now.addingTimeInterval(configuration.retryDelay)
            } else {
                entry.attempts = 0
                entry.retryAt = nil
            }
        case .blocked:
            entry.awaitingApproval = true
            entry.attempts = 0
            entry.retryAt = nil
        case .interrupted:
            entry.retryAt = now
        case .stopped:
            entry.attempts = 0
            entry.retryAt = nil
        case .running:
            break
        }
        state.tasks[key] = entry
        persist()

        notify(job.task, status, summary)
        refreshActivity()
        emit(.taskFinished(id, status, summary.message))
        startQueued()
    }

    func notify(_ task: SyncTask, _ status: RunStatus, _ summary: RunSummary) {
        if shuttingDown || status == .stopped || status == .interrupted || status == .running { return }
        let isError = status == .failed || status == .blocked || status == .quotaReached
        switch task.notifications {
        case .never: return
        case .errorsOnly: if !isError { return }
        case .always: break
        }
        let title: String
        switch status {
        case .succeeded: title = "\(task.name) : terminée"
        case .blocked: title = "\(task.name) : validation requise"
        case .quotaReached: title = "\(task.name) : quota atteint"
        default: title = "\(task.name) : échec"
        }
        let body = summary.message
            ?? "\(summary.filesTransferred) fichier(s), \(Formatting.bytes(summary.bytesTransferred))"
        notifier.notify(title: title, body: body)
    }

    // MARK: lecture

    public func listTasks() -> [SyncTask] { tasks }

    public func runHistory(taskID: UUID?, limit: Int) throws -> [RunRecord] {
        try history.list(taskID: taskID, limit: limit)
    }

    public func status() -> AgentStatus {
        let now = clock.now()
        let infos = tasks.map { task -> AgentTaskInfo in
            let entry = state.tasks[task.id.uuidString]
            let runState: TaskRunState
            if let job = jobs[task.id] {
                runState = job.paused ? .paused : .running
            } else if queue.contains(where: { $0.id == task.id }) {
                runState = .queued
            } else if !task.isEnabled {
                runState = .disabled
            } else if entry?.awaitingApproval == true {
                runState = .awaitingApproval
            } else if let reason = waiting[task.id] {
                runState = .waiting(reason: reason)
            } else {
                runState = .idle
            }
            let next = task.isEnabled ? entry.flatMap { dueDate(task, $0, now) } : nil
            let last = (try? history.list(taskID: task.id, limit: 1))?.first
            return AgentTaskInfo(id: task.id, name: task.name, state: runState, nextDue: next, lastRun: last)
        }
        return AgentStatus(
            globalPause: state.paused, stateRecovered: stateRecovered, taskLoadError: taskLoadError, tasks: infos
        )
    }

    /// Attend la fin de toutes les exécutions en cours (tests, arrêt de l'agent).
    public func waitForIdle() async {
        while let running = jobTasks.values.first { await running.value }
    }

    // MARK: observateurs

    public func addObserver(_ handler: @escaping @Sendable (AgentEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    func emit(_ event: AgentEvent) {
        for handler in observers.values { handler(event) }
    }

    func persist() {
        do { try stateStore.save(state) } catch { log("état non enregistré : \(error)") }
    }
}
