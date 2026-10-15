import Foundation

extension AgentCore {
    /// Lance la tâche maintenant, sans tenir compte de l'horaire ni des conditions.
    public func runNow(_ id: UUID) throws {
        try enqueueNow(id, overrideGuard: false)
    }

    /// L'utilisateur accepte les suppressions qui avaient bloqué la tâche : une exécution avec le seuil relevé.
    public func approveDeletion(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        guard state.tasks[id.uuidString]?.awaitingApproval == true else { throw AgentError.notAwaitingApproval }
        try enqueueNow(id, overrideGuard: true)
    }

    private func enqueueNow(_ id: UUID, overrideGuard: Bool) throws {
        guard !state.paused else { throw AgentError.globallyPaused }
        guard let task = tasks.first(where: { $0.id == id }) else { throw AgentError.unknownTask }
        // Disque amovible absent : aucun dossier n'est créé sous /Volumes, on le dit.
        if let drive = task.removableDrive, drives != nil, mountedDrives[drive.volumeUUID] == nil {
            throw AgentError.driveNotConnected(drive.volumeName)
        }
        guard jobs[id] == nil, !queue.contains(where: { $0.id == id }) else { throw AgentError.alreadyRunning }
        queue.insert(QueuedRun(id: id, dueDate: .distantPast, overrideGuard: overrideGuard, manual: true), at: 0)
        startQueued()
        emit(.stateChanged)
    }

    public func pause(_ id: UUID) throws {
        guard var job = jobs[id] else { throw AgentError.notRunning }
        guard !job.paused else { return }
        job.runner.pause()
        job.paused = true
        jobs[id] = job
        refreshActivity()
        emit(.stateChanged)
    }

    public func resume(_ id: UUID) throws {
        guard var job = jobs[id] else { throw AgentError.notRunning }
        guard !state.paused else { throw AgentError.globallyPaused }
        guard job.paused else { return }
        job.runner.resume()
        job.paused = false
        job.pausedByGlobal = false
        jobs[id] = job
        refreshActivity()
        emit(.stateChanged)
    }

    /// Arrête une exécution, ou retire la tâche de la file d'attente.
    public func stop(_ id: UUID) throws {
        if let job = jobs[id] {
            job.runner.stop()   // `TaskRunner` reprend d'abord un processus figé, puis l'arrête
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { throw AgentError.notRunning }
        queue.remove(at: index)
        oneOffs[id] = nil   // une copie ponctuelle retirée de la file n'existe plus
        emit(.stateChanged)
    }

    /// Pause globale : plus rien ne démarre, les exécutions en cours sont figées. Enregistrée sur le disque.
    public func setGlobalPause(_ paused: Bool) {
        guard paused != state.paused else { return }
        state.paused = paused
        persist()
        if paused {
            for id in Array(jobs.keys) {
                guard var job = jobs[id], !job.paused else { continue }
                job.runner.pause()
                job.paused = true
                job.pausedByGlobal = true
                jobs[id] = job
            }
        } else {
            for id in Array(jobs.keys) {
                guard var job = jobs[id], job.pausedByGlobal else { continue }
                job.runner.resume()
                job.paused = false
                job.pausedByGlobal = false
                jobs[id] = job
            }
            holdUntil = nil
            refreshActivity()
            tick()
        }
        refreshActivity()
        emit(.stateChanged)
    }

    /// Arrêt de l'agent (SIGTERM, déconnexion) : les exécutions sont arrêtées proprement,
    /// marquées « interrompues » et rattrapées au prochain démarrage.
    public func shutdown() async {
        shuttingDown = true
        // Une copie ponctuelle encore en file ne sera jamais reprise : l'historique le dit.
        let now = clock.now()
        for run in queue where jobs[run.id] == nil {
            guard let task = oneOffs.removeValue(forKey: run.id) else { continue }
            let record = RunRecord(
                taskID: task.id, taskName: task.name, engine: (try? EngineSelector.engine(for: task)) ?? .rsync,
                mode: task.mode, startedAt: now, finishedAt: now, status: .interrupted,
                summary: RunSummary(message: "Arrêt de l'agent avant le début de la copie.")
            )
            try? history.save(record)
        }
        for (id, task) in queuedOneOffs {
            let record = RunRecord(
                taskID: id, taskName: task.name, engine: (try? EngineSelector.engine(for: task)) ?? .rsync,
                mode: task.mode, startedAt: now, finishedAt: now, status: .interrupted,
                summary: RunSummary(message: "Arrêt de l'agent avant le début de la copie.")
            )
            try? history.save(record)
            state.userQueue.removeAll { $0 == id }
        }
        queuedOneOffs.removeAll()
        persist()
        queue.removeAll()
        for job in jobs.values { job.runner.stop() }
        for runner in simulations.values { runner.stop() }
        await stopRemoteConfigurations()
        await waitForIdle()
    }
}
