import Foundation

extension AgentCore {
    /// Crée ou remplace une tâche. Seul l'agent écrit `tasks.json`. Une exécution en cours continue avec l'ancienne
    /// version ; la nouvelle vaut pour la suivante.
    public func saveTask(_ task: SyncTask) throws {
        if let problem = TaskValidator.problems(in: task).first { throw AgentError.invalidTask(problem.message) }
        do { try taskStore.upsert(task) } catch { throw AgentError.internalFailure("tasks.json non enregistré : \(error)") }
        // Plus liée à ce disque (lien retiré ou autre disque) : la sauvegarde en pause ne reprendra jamais, elle est close.
        let key = task.id.uuidString
        if let suspended = state.tasks[key]?.suspendedRun,
           let previous = tasks.first(where: { $0.id == task.id })?.removableDrive?.volumeUUID,
           previous != task.removableDrive?.volumeUUID {
            close(suspended, message: "Interrompue : la tâche n'est plus liée au disque.", at: clock.now())
            state.tasks[key]?.suspendedRun = nil
            waiting[task.id] = nil
        }
        // Une tâche modifiée doit être replanifiée : une validation de suppressions ne vaut que pour l'ancienne version.
        state.tasks[task.id.uuidString]?.awaitingApproval = false
        if !task.isEnabled { queue.removeAll { $0.id == task.id } }   // désactivée : elle sort de l'attente
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
        if let suspended = state.tasks[id.uuidString]?.suspendedRun {
            close(suspended, message: "Interrompue : tâche supprimée.", at: clock.now())
            state.tasks[id.uuidString]?.suspendedRun = nil
        }
        if let work = configuration.workDirectory {
            for folder in ["bisync/\(id.uuidString)", "bl/\(id.uuidString.prefix(12))"] {
                try? FileManager.default.removeItem(at: work.appendingPathComponent(folder))
            }
        }
        queue.removeAll { $0.id == id }
        loadTasks()
        persist()
        emit(.stateChanged)
    }
}
