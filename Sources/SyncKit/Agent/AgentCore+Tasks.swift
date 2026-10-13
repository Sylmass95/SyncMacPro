import Foundation

extension AgentCore {
    /// Crée ou remplace une tâche. Seul l'agent écrit `tasks.json`. Une exécution en cours continue avec l'ancienne
    /// version ; la nouvelle vaut pour la suivante.
    public func saveTask(_ task: SyncTask) throws {
        if let problem = TaskValidator.problems(in: task).first { throw AgentError.invalidTask(problem.message) }
        do { try taskStore.upsert(task) } catch { throw AgentError.internalFailure("tasks.json non enregistré : \(error)") }
        // Une tâche modifiée doit être replanifiée : une validation de suppressions ne vaut que pour l'ancienne version.
        state.tasks[task.id.uuidString]?.awaitingApproval = false
        queue.removeAll { $0.id == task.id && $0.overrideGuard }
        loadTasks()
        persist()
        emit(.stateChanged)
    }

    /// Supprime une tâche ; refusé tant qu'elle tourne ou attend en file. L'historique est conservé.
    public func removeTask(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AgentError.unknownTask }
        guard jobs[id] == nil, !queue.contains(where: { $0.id == id }) else { throw AgentError.alreadyRunning }
        do { try taskStore.remove(id: id) } catch { throw AgentError.internalFailure("tasks.json non enregistré : \(error)") }
        loadTasks()
        persist()
        emit(.stateChanged)
    }
}
