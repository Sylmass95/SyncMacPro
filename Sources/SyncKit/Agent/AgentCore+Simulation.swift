import Foundation

extension AgentCore {
    /// Une simulation parcourt toute l'arborescence : deux à la fois au plus.
    static let maxSimulations = 2

    /// Simulation hors de la file : rien n'est écrit dans l'historique ni dans `tasks.json`.
    /// Une nouvelle simulation de la même tâche remplace la précédente.
    public func simulate(_ original: SyncTask) async throws -> SimulationResult {
        // Disque amovible : la comparaison se fait avec son dossier, là où il est monté maintenant.
        if let drive = original.removableDrive, ejectingVolumes.contains(drive.volumeUUID) {
            throw AgentError.ejectRefused("Le disque est en cours d'éjection.")
        }
        if let drive = original.removableDrive, drives != nil, mountedDrives[drive.volumeUUID] == nil {
            throw AgentError.driveNotConnected(drive.volumeName)
        }
        let task = resolvedForDrive(original)
        if let problem = TaskValidator.problems(in: task).first(where: { $0 != .emptyName }) {
            throw AgentError.invalidTask(problem.message)
        }
        // Un bidirectionnel en cours : bisync refuserait (verrou) et ses liens courts seraient repointés en pleine copie.
        if task.mode == .bidirectional && jobs[task.id] != nil { throw AgentError.alreadyRunning }
        if simulations[task.id] == nil && simulations.count >= Self.maxSimulations {
            throw AgentError.tooManySimulations
        }
        simulations[task.id]?.stop()
        let runner = makeRunner()
        simulations[task.id] = runner
        let outcome: SimulationResult
        do {
            outcome = SimulationResult(try await runner.run(task, dryRun: true, onUpdate: { _ in }))
        } catch {
            outcome = SimulationResult(status: .failed, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        if simulations[task.id] === runner { simulations[task.id] = nil }
        return outcome
    }

    public func cancelSimulation(_ id: UUID) {
        simulations[id]?.stop()
    }
}
