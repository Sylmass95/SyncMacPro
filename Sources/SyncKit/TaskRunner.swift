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
    public func setBandwidth(_ rate: BandwidthRate) { control.setBandwidth(rate) }

    // MARK: exécution

    public func run(
        _ task: SyncTask,
        dryRun: Bool = false,
        onUpdate: @escaping @Sendable (RunUpdate) -> Void = { _ in }
    ) async throws -> RunResult {
        let engine = try EngineSelector.engine(for: task)
        control.reset()
        if let message = await probeAccess(task) {
            return result(status: .failed, engine: engine, snapshot: TransferSnapshot(), started: configuration.now(),
                          errors: 1, message: message, retryable: true)
        }
        let stamp = Self.archiveStamp(configuration.now())
        var outcome: RunResult
        switch engine {
        case .rsync: outcome = try await runRsync(task, dryRun: dryRun, stamp: stamp, onUpdate: onUpdate)
        case .rclone: outcome = try await runRclone(task, dryRun: dryRun, stamp: stamp, onUpdate: onUpdate)
        }
        if let timeout = control.stalledAfter, outcome.status == .failed {
            outcome.summary.message = Self.stallMessage(after: timeout)
            outcome.retryable = true
        }
        return outcome
    }

    static func stallMessage(after timeout: TimeInterval) -> String {
        let delay = timeout >= 60 ? "\(Int(timeout / 60)) min" : "\(Int(timeout)) s"
        return "Aucune progression depuis \(delay) : le disque ou le NAS ne répond plus. "
            + "L'exécution a été arrêtée ; nouvel essai plus tard."
    }

    /// Surveillance d'un processus rsync contre les blocages (voir `StallWatchdog`). rclone a ses propres délais
    /// (`--timeout`, `--contimeout`) et écrit ses statistiques chaque seconde : il n'est pas surveillé.
    func makeWatch(for engine: EngineKind) -> EngineWatch {
        guard engine == .rsync, configuration.stallTimeout > 0 else { return EngineWatch(dog: nil, holder: Locked(nil)) }
        let holder = Locked<RunningProcess?>(nil)
        let timeout = configuration.stallTimeout
        let control = self.control
        let dog = StallWatchdog(
            timeout: timeout, interval: min(configuration.stallCheckInterval, timeout / 2),
            isPaused: { control.isPaused },
            cpuTime: { holder.get()?.groupCPUTime() },
            onStall: {
                control.markStalled(after: timeout)
                holder.get()?.terminateStalled(giveUpAfter: 60)
            }
        )
        return EngineWatch(dog: dog, holder: holder)
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
    /// `output` est la sortie standard seule (les résultats : JSON de `rclone size`, plan rsync, `check`) ;
    /// `errors` est la sortie d'erreur (journal JSON de rclone, avertissements). Les mélanger ferait échouer la lecture
    /// du JSON dès qu'un simple avertissement apparaît.
    func collect(_ command: EngineCommand) async throws -> (code: Int32, output: String, errors: String) {
        let out = LineBox(), err = LineBox()
        let code = try await stream(command, errors: { err.add($0) }) { out.add($0) }
        return (code, out.joined, err.joined)
    }

    /// Comme `collect`, mais chaque ligne de la sortie standard est passée à `onOutput` sans être gardée.
    func stream(
        _ command: EngineCommand, errors: (@Sendable (String) -> Void)? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let watch = makeWatch(for: command.engine)
        let process = try ProcessRunner.spawn(
            executable: try executable(for: command.engine), arguments: command.arguments
        ) { line in
            watch.note()
            if line.stream == .stderr { errors?(line.text) } else { onOutput(line.text) }
        }
        control.registerAuxiliary(process)
        watch.attach(process)
        let code = await process.waitForExit()
        watch.stop()
        return code
    }

    func result(
        status: RunStatus, engine: EngineKind, snapshot: TransferSnapshot, started: Date,
        deletions: Int = 0, errors: Int = 0, message: String? = nil, retryable: Bool = true
    ) -> RunResult {
        let duration = configuration.now().timeIntervalSince(started)
        return RunResult(
            status: status, engine: engine,
            summary: RunSummary(
                filesTransferred: snapshot.filesDone, bytesTransferred: snapshot.doneBytes,
                deletions: deletions, errors: errors,
                durationSeconds: duration, message: message,
                directories: snapshot.totalDirs.map { _ in snapshot.dirsDone },
                // Sur le temps actif (pauses exclues), comme la carte pendant la copie ; à défaut, la durée totale.
                averageSpeed: snapshot.doneBytes > 0
                    ? Double(snapshot.doneBytes) / (snapshot.activeTime > 0 ? snapshot.activeTime : max(duration, 0.001))
                    : nil
            ),
            snapshot: snapshot, retryable: retryable
        )
    }

    static func blockedMessage(percent: Int, deletions: Int, existing: Int, threshold: Int) -> String {
        "Bloqué : \(deletions) suppression(s) sur \(existing) fichier(s) (\(percent) %), "
            + "au-dessus du seuil de \(threshold) %. Rien n'a été modifié."
    }
}

/// Chien de garde d'un processus : créé avant le lancement (chaque ligne de sortie le nourrit), branché ensuite.
struct EngineWatch: Sendable {
    let dog: StallWatchdog?
    let holder: Locked<RunningProcess?>

    func note() { dog?.noteActivity() }
    func attach(_ process: RunningProcess) {
        holder.set(process)
        dog?.start()
    }
    func stop() { dog?.cancel() }
}

/// Collecte de lignes depuis plusieurs threads.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
