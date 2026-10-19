import Foundation

/// Plus de file explicite depuis 1.7.0 : la liste est la file. Les messages d'une app plus ancienne (pendant une mise à
/// jour) restent compris et sont redirigés.
extension AgentCore {
    /// « Mettre en file » : une demande « Lancer », qui part selon son rang.
    public func enqueue(_ id: UUID) throws { try runNow(id) }

    /// Copie ponctuelle « mise en file » : une copie ponctuelle, en haut de la liste.
    public func enqueueOnce(_ task: SyncTask) throws { try runOnce(task) }

    /// « Retirer de la file » : retirer de l'attente.
    public func dequeue(_ id: UUID) throws {
        guard jobs[id] == nil, queue.contains(where: { $0.id == id }) else { throw AgentError.notInQueue }
        try stop(id)
    }

    /// Ancienne place dans la file : nouveau rang dans la liste.
    public func moveInQueue(_ id: UUID, to index: Int) throws {
        guard state.order.contains(id) else { throw AgentError.notInQueue }
        var order = state.order.filter { $0 != id }
        order.insert(id, at: max(0, min(index, order.count)))
        reorder(order)
    }

    /// La liste n'a plus besoin d'être lancée.
    public func setQueueRunning(_ running: Bool) {}

    /// Lance tout de suite, même au-delà de deux copies ou sur un disque occupé ; reprend aussitôt une copie en pause.
    /// La pause globale et une mise à jour en attente restent prioritaires.
    public func force(_ id: UUID) throws {
        guard !state.paused else { throw AgentError.globallyPaused }
        try refuseWhileRestartPending()
        if var job = jobs[id] {
            guard job.paused else { return }
            job.runner.resume()
            job.paused = false
            job.pausedByGlobal = false
            job.resumeRequested = false
            jobs[id] = job
            refreshActivity()
            explainWaiting()
            emit(.stateChanged)
            return
        }
        guard let task = lookupTask(id) else { throw AgentError.unknownTask }
        if oneOffs[id] == nil && !task.isEnabled {
            throw AgentError.invalidTask("Tâche désactivée : activez-la avant de la lancer.")
        }
        if let drive = task.removableDrive, ejectingVolumes.contains(drive.volumeUUID) {
            throw AgentError.ejectRefused("Le disque est en cours d'éjection.")
        }
        if let drive = task.removableDrive, drives != nil, mountedDrives[drive.volumeUUID] == nil {
            throw AgentError.driveNotConnected(drive.volumeName)
        }
        let waitingRun = queue.first { $0.id == id }
        queue.removeAll { $0.id == id }
        startJob(task, overrideGuard: waitingRun?.overrideGuard ?? false, resuming: pendingResumes.removeValue(forKey: id))
        explainWaiting()
        emit(.stateChanged)
    }
}
