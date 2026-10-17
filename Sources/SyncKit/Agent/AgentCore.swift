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
        var logWriter: RunLogWriter?
        /// Élément de la file d'attente explicite.
        var fromUserQueue = false
        /// Disque amovible : débranché pendant l'exécution ; exécution suspendue reprise.
        var driveLost = false
        var resumed: SuspendedRun?
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
    /// Dossier des journaux d'exécution ; `nil` : pas de journal.
    let logDirectory: URL?

    var tasks: [SyncTask] = []
    var state: SchedulerState
    let stateRecovered: Bool
    var taskLoadError: String?
    var jobs: [UUID: Job] = [:]
    var jobTasks: [UUID: Task<Void, Never>] = [:]
    var queue: [QueuedRun] = []
    var waiting: [UUID: String] = [:]
    /// Identité du programme au démarrage, et vrai dès qu'une mise à jour l'a remplacé (1.6.7).
    var launchedIdentity: String?
    var restartPending = false
    var appOpenedForRestart = false
    var holdUntil: Date?
    var lastTick: Date?
    var shuttingDown = false
    /// Vrai tant que l'assertion anti-veille est tenue.
    var activityHeld = false
    var observers: [UUID: @Sendable (AgentEvent) -> Void] = [:]
    /// Simulations en cours, par tâche : une nouvelle simulation de la même tâche remplace la précédente.
    var simulations: [UUID: TaskRunning] = [:]
    /// Copies manuelles en file ou en cours (jamais écrites dans `tasks.json`).
    var oneOffs: [UUID: SyncTask] = [:]
    /// Connexions rclone ; `nil` : rclone introuvable.
    let remotes: RemoteConfiguring?
    /// Connexions dont une étape de configuration est en cours (une seule à la fois par nom).
    var configuringRemotes: Set<String> = []
    /// Connexions créées par l'assistant et pas encore terminées : supprimées si la création échoue ou est annulée.
    var creatingRemotes: Set<String> = []
    /// Annulations reçues pendant une étape (avant que rclone soit lancé).
    var cancelledRemotes: Set<String> = []
    /// Plafonds de débit des réglages, et type de chaque connexion rclone (réseau local ou internet).
    let settingsStore: AgentSettingsStore?
    var settingsLimits = BandwidthLimits()
    var remoteTypes: [String: String] = [:]
    var remoteTypesLoaded = false
    /// Disques amovibles : moniteur, volumes montés (UUID → point de montage) et date de leur branchement.
    let drives: DriveMonitor?
    /// Éjections automatiques en cours (attendues par `waitForIdle`).
    var ejectTasks: [UUID: Task<Void, Never>] = [:]
    /// Volumes en cours d'éjection : ni seconde éjection ni nouvelle exécution dessus.
    var ejectingVolumes: Set<String> = []
    /// Faux tant que les volumes n'ont pas été lus une première fois : seule cette lecture se fie à l'heure
    /// d'apparition du disque (redémarrage de l'agent) ; ensuite, un montage signalé est un branchement.
    var drivesPrimed = false
    var mountedDrives: [String: String] = [:]
    var mountSeen: [String: Date] = [:]
    /// Copies ponctuelles mises en file d'attente (jamais enregistrées) et élément de la file en cours.
    var queuedOneOffs: [UUID: SyncTask] = [:]
    var userQueueCurrent: UUID? {
        get { state.userQueueCurrent }
        set { state.userQueueCurrent = newValue }
    }

    public init(
        configuration: AgentConfiguration, taskStore: TaskStore, stateStore: SchedulerStateStore,
        history: HistoryStore, clock: SchedulerClock, conditions: SystemConditions,
        notifier: AgentNotifier, activity: ActivityHolding,
        log: @escaping @Sendable (String) -> Void = { _ in },
        logDirectory: URL? = nil,
        remotes: RemoteConfiguring? = nil,
        settingsStore: AgentSettingsStore? = nil,
        drives: DriveMonitor? = nil,
        makeRunner: @escaping @Sendable () -> TaskRunning
    ) {
        self.drives = drives
        self.settingsStore = settingsStore
        self.logDirectory = logDirectory
        self.remotes = remotes
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
        launchedIdentity = configuration.executableIdentity()
        loadTasks()
        settingsLimits = settingsStore?.load() ?? BandwidthLimits()
        _ = try? history.markRunningAsInterrupted(at: now)
        // Une tâche encore « en cours » dans l'état : l'agent a été tué en route. Elle sera rattrapée.
        for key in state.tasks.keys where state.tasks[key]?.runningSince != nil {
            state.tasks[key]?.runningSince = nil
            // Une tâche liée à un disque repart au branchement, pas par un nouvel essai : le branchement en cours est
            // de nouveau à servir (disque resté branché pendant le redémarrage).
            let linked = tasks.contains { $0.id.uuidString == key && $0.removableDrive != nil }
            state.tasks[key]?.retryAt = linked ? nil : now
            if linked { state.tasks[key]?.lastMountHandled = nil }
        }
        if configuration.startupHold > 0 { holdUntil = now.addingTimeInterval(configuration.startupHold) }
        // L'élément en cours au moment de l'arrêt est repris par le rattrapage : la file l'attend. Disparu : oublié.
        // Une tâche liée n'est pas rattrapée (elle repart au branchement) : la file ne l'attend pas.
        if let current = userQueueCurrent, !tasks.contains(where: { $0.id == current && $0.removableDrive == nil }) {
            userQueueCurrent = nil
        }
        state.userQueueRunning = state.userQueueRunning && (!state.userQueue.isEmpty || userQueueCurrent != nil)
        persist()
        advanceUserQueue()
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
        // Une tâche supprimée ne reste pas dans la file d'attente.
        state.userQueue = state.userQueue.filter { known.contains($0.uuidString) || queuedOneOffs[$0] != nil }
    }

    // MARK: évaluation

    /// Appelée chaque minute et à chaque réveil par le programme de l'agent.
    public func tick() {
        let now = clock.now()
        defer { lastTick = now }
        // Secours si un avis de DiskArbitration a été manqué : les volumes sont relus à chaque passage.
        if let drives, drives.mountedVolumes() != mountedDrives { drivesChanged() }
        if let last = lastTick, now.timeIntervalSince(last) > configuration.wakeGap {
            holdUntil = now.addingTimeInterval(configuration.wakeHold)
        }
        purgeHistoryIfNeeded(now)
        checkReplacedProgram()
        // Au repos et en attente : l'app est ouverte pour qu'elle redémarre l'agent (une fois).
        if restartPending, jobs.isEmpty, !appOpenedForRestart {
            appOpenedForRestart = true
            configuration.openApp()
        }
        guard !state.paused else { return }
        if let hold = holdUntil {
            if now < hold { return }
            holdUntil = nil
        }
        var changed = false
        // Les tâches d'un disque amovible partent au branchement (`handleDrives`), pas selon une échéance.
        for task in tasks where task.isEnabled && task.removableDrive == nil {
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
            if restartPending {   // due : elle partira après le redémarrage (toujours due)
                waiting[task.id] = Self.restartReason
                continue
            }
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
        handleDrives(now)
        advanceUserQueue()   // après une pause globale levée, ou une place libérée
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
        if let drive = task.removableDrive, drives != nil, mountedDrives[drive.volumeUUID] == nil {
            return "disque « \(drive.volumeName) » non branché"
        }
        // Partage réseau non monté : l'exécution le monte, ou la tâche attend le NAS (1.6.5).
        if !conditions.isReachable(task.source) && !task.source.isMountableShare { return "source inaccessible" }
        // Disque amovible branché : il suffit (le dossier d'un disque neuf est créé par le moteur, et le chemin
        // enregistré peut viser un ancien point de montage).
        let onDrive = task.removableDrive != nil && drives != nil
        if !onDrive && !conditions.isReachable(task.destination) && !task.destination.isMountableShare {
            return "destination inaccessible"
        }
        return nil
    }

    func purgeHistoryIfNeeded(_ now: Date) {
        if let last = state.lastPurge, now.timeIntervalSince(last) < 86400 { return }
        let limit = now.addingTimeInterval(-Double(configuration.historyRetentionDays) * 86400)
        _ = try? history.purge(finishedBefore: limit)
        if let logDirectory { removeLogs(in: logDirectory, olderThan: limit) }
        state.lastPurge = now
        persist()
    }

    func removeLogs(in folder: URL, olderThan limit: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < limit { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Vide l'historique (tout, ou celui d'une tâche) et supprime les journaux correspondants. Une exécution en cours
    /// reste. Seuls les fichiers du dossier des journaux sont effacés. Retourne le nombre d'exécutions supprimées.
    public func clearHistory(taskID: UUID?) throws -> Int {
        let removed: (count: Int, logPaths: [String])
        do { removed = try history.clear(taskID: taskID) } catch {
            throw AgentError.internalFailure("historique non vidé : \(error)")
        }
        if let logDirectory {
            let folder = logDirectory.standardizedFileURL.path + "/"
            for path in removed.logPaths where URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(folder) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        emit(.stateChanged)
        return removed.count
    }

    public func runLog(runID: UUID, maxBytes: Int) throws -> RunLogText {
        guard let record = try history.record(id: runID), let path = record.logPath,
              FileManager.default.fileExists(atPath: path) else { throw AgentError.unknownRun }
        return try RunLogWriter.readTail(url: URL(fileURLWithPath: path), maxBytes: maxBytes)
    }

    // MARK: exécution

    func startQueued() {
        guard !state.paused, !shuttingDown else { return }
        checkReplacedProgram()
        if restartPending { keepQueuedForRestart(); return }
        // Exécutions qui attendent leur disque (éjection en cours, ou une autre copie sur ce disque) : elles gardent
        // leur place, les suivantes prennent les places libres.
        var waitingForDrive: [QueuedRun] = []
        defer { queue.insert(contentsOf: waitingForDrive, at: 0) }
        while jobs.count < configuration.maxParallel, !queue.isEmpty {
            let next = queue.removeFirst()
            guard let task = lookupTask(next.id), jobs[task.id] == nil else { continue }
            if let drive = task.removableDrive, ejectingVolumes.contains(drive.volumeUUID) || driveBusy(task) {
                waitingForDrive.append(next)
                continue
            }
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

    func startJob(_ original: SyncTask, overrideGuard: Bool, resuming: SuspendedRun? = nil) {
        // Garde-fou : une tâche liée ne part jamais sans son disque (le chemin enregistré pourrait être un autre disque
        // du même nom).
        if driveMissing(original) {
            log("« \(original.name) » : disque non branché, exécution non lancée")
            return
        }
        // Disque amovible : la destination suit le point de montage actuel du volume.
        let task = resolvedForDrive(original)
        var runTask = task
        if overrideGuard { runTask.options.deleteThresholdPercent = 100 }
        let now = clock.now()
        let key = task.id.uuidString
        // Lancée à la main (ou par la file) pendant une suspension : c'est une reprise, dans le délai ; au-delà,
        // l'exécution suspendue est close.
        var resuming = resuming
        if resuming == nil, let drive = original.removableDrive, let suspended = state.tasks[key]?.suspendedRun {
            state.tasks[key]?.suspendedRun = nil
            if now.timeIntervalSince(suspended.since) <= Double(drive.resumeWindowDays) * 86_400 {
                resuming = suspended
            } else {
                close(suspended, message: "Interrompue : disque débranché plus de \(drive.resumeWindowDays) jour(s).", at: now)
            }
        }
        let engine = (try? EngineSelector.engine(for: runTask)) ?? .rsync
        var record = RunRecord(taskID: task.id, taskName: task.name, engine: engine, mode: task.mode, startedAt: now)
        if let resuming, var previous = try? history.record(id: resuming.recordID) {
            previous.status = .running
            previous.finishedAt = nil
            previous.summary = nil   // le bilan cumulé est reposé à la fin (`combine`)
            record = previous   // même ligne d'historique : l'exécution suspendue continue
        }
        var writer: RunLogWriter?
        if let logDirectory, resuming == nil || record.logPath == nil {
            let url = logDirectory.appendingPathComponent("\(record.id.uuidString).log")
            record.logPath = url.path
            let clock = self.clock
            let created = RunLogWriter(url: url, now: { clock.now() })
            created.append("Tâche « \(task.name) » — moteur \(engine.rawValue), mode \(task.mode.rawValue)")
            writer = created
        }
        try? history.save(record)

        // Lancée hors de la file (« Lancer », horaire) : elle n'y attend plus son tour.
        if userQueueCurrent != task.id { state.userQueue.removeAll { $0 == task.id } }
        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.lastStart = now
        entry.runningSince = now
        entry.retryAt = nil
        entry.awaitingApproval = false
        // Ce branchement est servi (à la main, par la file ou au branchement) : pas de deuxième sauvegarde.
        if let drive = original.removableDrive { entry.lastMountHandled = mountSeen[drive.volumeUUID] ?? now }
        state.tasks[key] = entry
        persist()

        let runner = makeRunner()
        if resuming != nil, writer == nil, let path = record.logPath {
            let clock = self.clock
            let reopened = RunLogWriter(url: URL(fileURLWithPath: path), now: { clock.now() }, append: true)
            reopened.append("Reprise : disque rebranché.")
            writer = reopened
        }
        jobs[task.id] = Job(task: task, runner: runner, record: record, logWriter: writer, resumed: resuming)
        applyBandwidth()   // la limite de départ est connue avant `run`
        waiting[task.id] = nil
        refreshActivity()
        emit(.taskStarted(task.id))

        // Copies immuables : Swift 5.10 refuse de capturer une `var` (ou un `weak self`) dans une closure concurrente.
        // La référence forte à l'acteur dure le temps de l'exécution, que `jobTasks` tient de toute façon.
        let id = task.id
        let frozenTask = runTask
        let logWriter = writer
        let core = self
        jobTasks[id] = Task.detached {
            let outcome: Result<RunResult, Error>
            do {
                outcome = .success(try await runner.run(frozenTask, dryRun: false) { update in
                    switch update {
                    case .snapshot(let snapshot): Task { await core.progress(id, snapshot) }
                    case .line(let text): logWriter?.append(text)
                    case .phase: break
                    }
                })
            } catch {
                outcome = .failure(error)
            }
            await core.finish(id, outcome)
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

    func finish(_ id: UUID, _ outcome: Result<RunResult, Error>, rechecked: Bool = false) {
        // Disque arraché : l'erreur d'entrée/sortie peut précéder la disparition du volume. Un échec alors que le
        // volume est encore listé est réexaminé un peu plus tard (suspension s'il a disparu entre-temps).
        if !rechecked, let job = jobs[id], let drive = job.task.removableDrive, !job.driveLost, !shuttingDown,
           configuration.driveFailureRecheck > 0, currentMountPath(drive) != nil, Self.failed(outcome) {
            let delay = UInt64(configuration.driveFailureRecheck * 1_000_000_000)
            let core = self
            jobTasks[id] = Task.detached {
                try? await Task.sleep(nanoseconds: delay)
                await core.finish(id, outcome, rechecked: true)
            }
            return
        }
        jobTasks[id] = nil
        guard var job = jobs.removeValue(forKey: id) else { return }
        applyBandwidth()   // une exécution de moins : les autres récupèrent sa part
        let now = clock.now()
        var status: RunStatus
        var summary: RunSummary
        var retryable = true
        switch outcome {
        case .success(let result):
            status = result.status
            summary = result.summary
            retryable = result.retryable
        case .failure(let error):
            status = .failed
            summary = RunSummary(
                errors: 1, durationSeconds: now.timeIntervalSince(job.record.startedAt),
                message: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        if shuttingDown && status == .stopped { status = .interrupted }
        if let previous = job.resumed { summary = Self.combine(previous.summary, summary) }
        if let drive = job.task.removableDrive, status != .succeeded, !shuttingDown,
           job.driveLost || (status == .failed && currentMountPath(drive) == nil) {
            suspendForDrive(job, drive: drive, summary: summary, now: now)
            return
        }
        // Partage réseau injoignable : attente et nouvel essai. Pas pour une tâche liée à un disque (elle part au
        // branchement, `tick` ne la reprendrait pas), une copie ponctuelle ou une reprise : échec comme avant.
        let shareFailure: String? = { if case .success(let result) = outcome, status == .failed { return result.shareUnavailable }; return nil }()
        if let share = shareFailure, job.task.removableDrive == nil, job.resumed == nil, oneOffs[id] == nil, !shuttingDown,
           waitForShare(job, share: share, now: now) {
            emit(.taskFinished(id, status, summary.message))   // l'interface relit l'historique (ligne effacée)
            afterJob(id)
            return
        }

        job.record.status = status
        job.record.summary = summary
        job.record.finishedAt = now
        try? history.save(job.record)
        job.logWriter?.append("Fin : \(status.rawValue)" + (summary.message.map { " — \($0)" } ?? ""), force: true)
        job.logWriter?.close()

        let key = id.uuidString
        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.runningSince = nil
        // Au-delà de la limite, l'attente reste datée : les échecs suivants du partage suivent la règle ordinaire
        // (nouvel essai dans 1 h, 3 fois) au lieu de rouvrir 12 h d'essais toutes les 5 min.
        if shareFailure == nil { entry.shareWaitSince = nil }
        switch status {
        case .succeeded:
            entry.lastSuccess = now
            entry.attempts = 0
            entry.retryAt = nil
        case .failed where !retryable:
            // Des différences trouvées par une vérification ne sont pas une panne passagère : relancer ne changerait rien.
            // Une vérification qui n'a pas pu se faire (NAS absent, réseau coupé), elle, est retentée.
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
        // Une copie ponctuelle n'existe que le temps de son exécution : elle n'est jamais rattrapée.
        let wasOneOff = oneOffs.removeValue(forKey: id) != nil
        if wasOneOff {
            state.tasks[key] = nil
            persist()
        }

        if status == .succeeded, let drive = job.task.removableDrive, !shuttingDown {
            finishedOnDrive(job.task, drive: drive, summary: summary)
        } else {
            notify(job.task, status, summary, oneOff: wasOneOff)
        }
        refreshActivity()
        defer { handleDrives(now) }   // une place libérée : un disque branché entre-temps peut partir
        emit(.taskFinished(id, status, summary.message))
        startQueued()
        // À l'arrêt de l'agent, l'élément interrompu reste « en cours » : il sera repris avant le suivant.
        if userQueueCurrent == id && !shuttingDown { userQueueCurrent = nil; persist() }
        advanceUserQueue()
    }

    /// Partage réseau injoignable (1.6.5) : l'essai est effacé (ni échec ni notification) et la tâche attend un nouvel
    /// essai. Faux au-delà de `shareWaitLimit` : l'échec est alors enregistré comme d'habitude.
    func waitForShare(_ job: Job, share: String, now: Date) -> Bool {
        let key = job.task.id.uuidString
        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        let since = entry.shareWaitSince ?? job.record.startedAt
        guard now.timeIntervalSince(since) < configuration.shareWaitLimit else { return false }
        let retry = now.addingTimeInterval(configuration.shareRetryDelay)
        entry.shareWaitSince = since
        entry.runningSince = nil
        entry.retryAt = retry
        state.tasks[key] = entry
        persist()
        try? history.delete(id: job.record.id)
        job.logWriter?.close()
        if let path = job.record.logPath { try? FileManager.default.removeItem(atPath: path) }
        let formatter = DateFormatter()
        formatter.calendar = clock.calendar
        formatter.timeZone = clock.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        waiting[job.task.id] = "partage « \(share) » injoignable, nouvel essai à \(formatter.string(from: retry))"
        log("« \(job.task.name) » : partage « \(share) » injoignable, nouvel essai à \(formatter.string(from: retry))")
        return true
    }

    static let restartReason = "mise à jour installée : départ après le redémarrage de l'agent"

    /// Une mise à jour a remplacé le programme de l'agent : macOS ne reconnaît plus celui qui tourne (autorisations
    /// refusées, essai réel du 17/10). Plus rien ne démarre ; les copies en cours finissent, puis l'app le réenregistre.
    func checkReplacedProgram() {
        guard !restartPending, let launched = launchedIdentity, let current = configuration.executableIdentity(),
              current != launched else { return }
        restartPending = true
        log("programme de l'agent remplacé (mise à jour) : plus de nouveau départ avant le redémarrage")
        notifier.notify(
            title: "SyncMacPro a été mis à jour",
            body: "Les copies en cours se terminent, puis l'agent redémarre ; les tâches en attente partiront ensuite."
        )
        keepQueuedForRestart()
        emit(.stateChanged)
    }

    /// Exécutions en attente d'une place : celles demandées à la main sont notées pour l'agent suivant (une échéance
    /// passée part à son démarrage) ; les autres sont de toute façon dues.
    /// Demandes qui ne survivraient pas au redémarrage : refusées pendant l'attente.
    func refuseWhileRestartPending() throws {
        checkReplacedProgram()
        if restartPending { throw AgentError.restartPending }
    }

    func keepQueuedForRestart() {
        var changed = false
        for run in queue where run.manual && oneOffs[run.id] == nil {
            guard let task = lookupTask(run.id), task.removableDrive == nil else { continue }
            let key = run.id.uuidString
            var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: clock.now())
            if entry.retryAt == nil || entry.retryAt! > clock.now() { entry.retryAt = clock.now(); state.tasks[key] = entry; changed = true }
        }
        if changed { persist() }
    }

    static func failed(_ outcome: Result<RunResult, Error>) -> Bool {
        switch outcome {
        case .success(let result): return result.status == .failed
        case .failure: return true
        }
    }

    func notify(_ task: SyncTask, _ status: RunStatus, _ summary: RunSummary, oneOff: Bool = false, note: String? = nil) {
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
        let body = (summary.message
            ?? "\(summary.filesTransferred) fichier(s), \(Formatting.bytes(summary.bytesTransferred))") + (note.map { " — \($0)" } ?? "")
        // Une copie ponctuelle n'existe plus après son exécution : il n'y a rien à valider, on explique comment relancer.
        if oneOff && status == .blocked {
            notifier.notify(
                title: "\(task.name) : bloquée",
                body: body + " Relancez-la depuis l'écran Copie après une simulation, en acceptant les suppressions."
            )
            return
        }
        notifier.notify(title: title, body: body)
    }

    // MARK: lecture

    public func listTasks() -> [SyncTask] { tasks }

    public func runHistory(taskID: UUID?, limit: Int) throws -> [RunRecord] {
        try history.list(taskID: taskID, limit: limit)
    }

    public func status() -> AgentStatus {
        let now = clock.now()
        let ponctual = (Array(oneOffs.values) + Array(queuedOneOffs.values)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let infos = (tasks + ponctual).map { task -> AgentTaskInfo in
            let entry = state.tasks[task.id.uuidString]
            let runState: TaskRunState
            if let job = jobs[task.id] {
                runState = job.paused ? .paused : .running
            } else if queue.contains(where: { $0.id == task.id }) {
                runState = restartPending ? .waiting(reason: Self.restartReason) : .queued
            } else if !task.isEnabled {
                runState = .disabled
            } else if entry?.awaitingApproval == true {
                runState = .awaitingApproval
            } else if let suspended = entry?.suspendedRun, driveMissing(task) {
                runState = .waiting(reason: "disque débranché depuis \(Self.elapsed(since: suspended.since, now: now))")
            } else if entry?.suspendedRun != nil, waiting[task.id] == nil {
                runState = .waiting(reason: "reprise imminente")   // disque revenu : la reprise part après l'attente
            } else if let reason = waiting[task.id] {
                runState = .waiting(reason: reason)
            } else {
                runState = .idle
            }
            // Une tâche liée à un disque part au branchement : aucune échéance à annoncer.
            let next = task.isEnabled && task.removableDrive == nil ? entry.flatMap { dueDate(task, $0, now) } : nil
            let last = (try? history.list(taskID: task.id, limit: 1))?.first
            return AgentTaskInfo(
                id: task.id, name: task.name, state: runState, nextDue: next, lastRun: last,
                progress: jobs[task.id]?.latest, isOneOff: oneOffs[task.id] != nil || queuedOneOffs[task.id] != nil,
                queuePosition: state.userQueue.firstIndex(of: task.id).map { $0 + 1 },
                driveSuspendedSince: entry?.suspendedRun?.since,
                driveMounted: task.removableDrive.flatMap { drive in drives == nil ? nil : mountedDrives[drive.volumeUUID] != nil }
            )
        }
        return AgentStatus(
            globalPause: state.paused, stateRecovered: stateRecovered, taskLoadError: taskLoadError, tasks: infos,
            queue: queueInfo, bandwidth: settingsLimits, restartPending: restartPending
        )
    }

    /// Attend la fin de toutes les exécutions en cours (tests, arrêt de l'agent).
    public func waitForIdle() async {
        while let running = jobTasks.values.first ?? ejectTasks.values.first { await running.value }
    }

    // MARK: débit

    public func setBandwidth(_ limits: BandwidthLimits) {
        settingsLimits = limits
        do { try settingsStore?.save(limits) } catch { log("réglages non enregistrés : \(error)") }
        applyBandwidth()
        emit(.stateChanged)
    }

    /// Recalcule la part de chaque exécution et la transmet (départ, fin, réglage modifié).
    func applyBandwidth() {
        let running = jobs.map { (id: $0.key, task: $0.value.task) }
        let rates = BandwidthPlanner.rates(for: running, limits: settingsLimits, remoteTypes: remoteTypes)
        for (id, rate) in rates { jobs[id]?.runner.setBandwidth(rate) }
    }

    /// Types des connexions rclone (réseau local ou internet) : relus au démarrage et après une modification.
    public func refreshRemoteTypes() async {
        guard let remotes else { return }
        // Liste illisible : on garde les types connus, mais la file n'attend pas indéfiniment.
        if let list = try? await remotes.listRemotes() {
            remoteTypes = Dictionary(list.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
        }
        remoteTypesLoaded = true
        applyBandwidth()
        advanceUserQueue()
    }

    // MARK: observateurs

    public func addObserver(_ handler: @escaping @Sendable (AgentEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    var observerCount: Int { observers.count }

    func emit(_ event: AgentEvent) {
        for handler in observers.values { handler(event) }
    }

    func persist() {
        do { try stateStore.save(state) } catch { log("état non enregistré : \(error)") }
    }
}
