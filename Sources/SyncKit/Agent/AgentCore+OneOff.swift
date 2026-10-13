import Foundation

extension AgentCore {
    /// Exécute une tâche sans l'enregistrer (copie manuelle) : même file, mêmes garde-fous, même journal ;
    /// elle figure dans l'état le temps de l'exécution, puis seulement dans l'historique.
    public func runOnce(_ task: SyncTask) throws {
        if let problem = TaskValidator.problems(in: task).first { throw AgentError.invalidTask(problem.message) }
        guard !state.paused else { throw AgentError.globallyPaused }
        guard lookupTask(task.id) == nil else { throw AgentError.alreadyRunning }
        // Devant les exécutions planifiées, derrière les copies déjà demandées (ordre des demandes).
        let index = queue.lastIndex(where: { oneOffs[$0.id] != nil }).map { $0 + 1 } ?? 0
        oneOffs[task.id] = task
        queue.insert(QueuedRun(id: task.id, dueDate: .distantPast, manual: true), at: index)
        startQueued()
        emit(.stateChanged)
    }

    /// Une tâche enregistrée ou une copie ponctuelle en cours.
    func lookupTask(_ id: UUID) -> SyncTask? {
        tasks.first(where: { $0.id == id }) ?? oneOffs[id]
    }
}
