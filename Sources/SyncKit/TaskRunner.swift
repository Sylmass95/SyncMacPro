import Foundation

/// Exécute une tâche avec rsync ou rclone et suit son avancement.
/// Une instance exécute une tâche à la fois ; l'agent en crée une par exécution.
public final class TaskRunner: @unchecked Sendable {
    let configuration: RunnerConfiguration
    let control = RunControl()

    public init(configuration: RunnerConfiguration) {
        self.configuration = configuration
    }

    // MARK: contrôle

    public func pause() { control.pause() }
    public func resume() { control.resume() }
    public func stop() { control.stop() }

    // MARK: exécution

    public func run(
        _ task: SyncTask,
        dryRun: Bool = false,
        onUpdate: @escaping @Sendable (RunUpdate) -> Void = { _ in }
    ) async throws -> RunResult {
        let engine = try EngineSelector.engine(for: task)
        control.reset()
        let stamp = Self.archiveStamp(configuration.now())
        switch engine {
        case .rsync: return try await runRsync(task, dryRun: dryRun, stamp: stamp, onUpdate: onUpdate)
        case .rclone: return try await runRclone(task, dryRun: dryRun, stamp: stamp, onUpdate: onUpdate)
        }
    }

    /// Nom du sous-dossier d'archive, par exemple « 2026-10-12_14-30-05 ».
    public static func archiveStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    // MARK: aides partagées

    func executable(for engine: EngineKind) throws -> String {
        let path = engine == .rsync ? configuration.rsyncPath : configuration.rclonePath
        guard let path else { throw RunnerError.binaryMissing(engine) }
        return path
    }

    /// Lance une commande annexe (simulation, taille, vérification) et attend sa fin.
    func collect(_ command: EngineCommand) async throws -> (code: Int32, output: String) {
        let box = LineBox()
        let process = try ProcessRunner.spawn(
            executable: try executable(for: command.engine), arguments: command.arguments
        ) { box.add($0.text) }
        control.registerAuxiliary(process)
        let code = await process.waitForExit()
        return (code, box.joined)
    }

    func result(
        status: RunStatus, engine: EngineKind, snapshot: TransferSnapshot, started: Date,
        deletions: Int = 0, errors: Int = 0, message: String? = nil
    ) -> RunResult {
        RunResult(
            status: status, engine: engine,
            summary: RunSummary(
                filesTransferred: snapshot.filesDone, bytesTransferred: snapshot.doneBytes,
                deletions: deletions, errors: errors,
                durationSeconds: configuration.now().timeIntervalSince(started), message: message
            ),
            snapshot: snapshot
        )
    }

    static func blockedMessage(percent: Int, deletions: Int, existing: Int, threshold: Int) -> String {
        "Bloqué : \(deletions) suppression(s) sur \(existing) fichier(s) (\(percent) %), "
            + "au-dessus du seuil de \(threshold) %. Rien n'a été modifié."
    }
}

/// Collecte de lignes depuis plusieurs threads.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
