import Foundation

extension AgentCore {
    /// Simulation hors de la file : rien n'est écrit dans l'historique ni dans `tasks.json`.
    /// Une nouvelle simulation de la même tâche remplace la précédente.
    public func simulate(_ task: SyncTask) async throws -> SimulationResult {
        if let problem = TaskValidator.problems(in: task).first(where: { $0 != .emptyName }) {
            throw AgentError.invalidTask(problem.message)
        }
        simulations[task.id]?.stop()
        let runner = makeRunner()
        simulations[task.id] = runner
        let outcome: SimulationResult
        do {
            outcome = SimulationResult(try await runner.run(task, dryRun: true, onUpdate: { _ in }))
        } catch {
            outcome = SimulationResult(status: .failed, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: "\(error)")
        }
        if simulations[task.id] === runner { simulations[task.id] = nil }
        return outcome
    }

    public func cancelSimulation(_ id: UUID) {
        simulations[id]?.stop()
    }
}
