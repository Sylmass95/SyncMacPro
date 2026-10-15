import Foundation

/// Ce que l'agent attend d'un exécuteur de tâche ; `TaskRunner` y répond, les tests utilisent un faux.
public protocol TaskRunning: AnyObject, Sendable {
    func run(
        _ task: SyncTask, dryRun: Bool, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult
    func pause()
    func resume()
    func stop()
    /// Limite de débit de l'exécution : appelée avant `run` (limite de départ) puis à chaque changement.
    func setBandwidth(_ rate: BandwidthRate)
}

extension TaskRunner: TaskRunning {}
