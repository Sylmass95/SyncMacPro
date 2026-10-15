import Foundation

/// File d'attente explicite : des tâches lancées une par une, dans l'ordre choisi, après « Lancer la file ».
extension AgentCore {
    public var queueInfo: QueueInfo {
        QueueInfo(running: state.userQueueRunning, items: state.userQueue, current: userQueueCurrent)
    }

    public func enqueue(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        try ensureNotBusy(id)
        state.userQueue.append(id)
        persist()
        emit(.stateChanged)
        advanceUserQueue()
    }

    /// Copie ponctuelle mise en file depuis l'écran Copie : gardée en mémoire seulement.
    public func enqueueOnce(_ task: SyncTask) throws {
        if let problem = TaskValidator.problems(in: task).first { throw AgentError.invalidTask(problem.message) }
        guard lookupTask(task.id) == nil else { throw AgentError.alreadyRunning }
        try ensureNotBusy(task.id)
        queuedOneOffs[task.id] = task
        state.userQueue.append(task.id)
        persist()
        emit(.stateChanged)
        advanceUserQueue()
    }

    public func dequeue(_ id: UUID) throws {
        guard let index = state.userQueue.firstIndex(of: id) else { throw AgentError.notRunning }
        state.userQueue.remove(at: index)
        queuedOneOffs[id] = nil
        persist()
        emit(.stateChanged)
    }

    public func moveInQueue(_ id: UUID, to index: Int) throws {
        guard let from = state.userQueue.firstIndex(of: id) else { throw AgentError.notRunning }
        state.userQueue.remove(at: from)
        state.userQueue.insert(id, at: max(0, min(index, state.userQueue.count)))
        persist()
        emit(.stateChanged)
    }

    /// Lancer ou suspendre la file. Suspendue, elle laisse finir son élément en cours et ne démarre plus rien.
    public func setQueueRunning(_ running: Bool) {
        state.userQueueRunning = running && (!state.userQueue.isEmpty || userQueueCurrent != nil)
        persist()
        emit(.stateChanged)
        advanceUserQueue()
    }

    private func ensureNotBusy(_ id: UUID) throws {
        guard jobs[id] == nil, !queue.contains(where: { $0.id == id }), !state.userQueue.contains(id) else {
            throw AgentError.alreadyRunning
        }
    }

    /// Démarre le premier élément si la file tourne, qu'aucun de ses éléments ne s'exécute et qu'il reste de la place.
    /// L'élément quitte la file au démarrage.
    func advanceUserQueue() {
        guard state.userQueueRunning, !state.paused, !shuttingDown, userQueueCurrent == nil else { return }
        // Éléments devenus impossibles (tâche supprimée ou désactivée) : sautés.
        while let first = state.userQueue.first,
              queuedOneOffs[first] == nil, !tasks.contains(where: { $0.id == first && $0.isEnabled }) {
            state.userQueue.removeFirst()
        }
        guard let next = state.userQueue.first else {
            state.userQueueRunning = false
            persist()
            emit(.stateChanged)
            return
        }
        guard jobs.count < configuration.maxParallel, jobs[next] == nil else { return }
        state.userQueue.removeFirst()
        if let copy = queuedOneOffs.removeValue(forKey: next) { oneOffs[next] = copy }
        persist()
        guard let task = lookupTask(next) else { advanceUserQueue(); return }
        userQueueCurrent = next
        startJob(task, overrideGuard: false)
        jobs[next]?.fromUserQueue = true
        emit(.stateChanged)
    }
}
