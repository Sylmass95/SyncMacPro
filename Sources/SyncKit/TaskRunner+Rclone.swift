import Foundation

extension TaskRunner {
    func runRclone(
        _ task: SyncTask, dryRun: Bool, stamp: String, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        let rclone = try executable(for: .rclone)
        let started = configuration.now()
        var options = RunOptions(dryRun: dryRun, archiveStamp: stamp, rcloneConfigPath: configuration.rcloneConfigPath)
        onUpdate(.phase(.preparing))

        if task.mode == .verify {
            return try await verifyWithRclone(task, options: options, started: started, onUpdate: onUpdate)
        }

        if task.mode == .bidirectional {
            let workdir = configuration.workDirectory.appendingPathComponent("bisync/\(task.id.uuidString)")
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            options.bisyncWorkdir = workdir.path
            options.resync = !Self.hasBisyncState(at: workdir)     // première exécution : initialisation
        }

        // Garde-fou des modes qui suppriment : simulation d'abord, avant de toucher à quoi que ce soit.
        if (task.mode == .mirror || task.mode == .versioned) && !dryRun {
            onUpdate(.phase(.planning))
            let guardResult = try await mirrorGuard(task, options: options)
            if let failure = guardResult.failure {
                return result(status: control.stopRequested ? .stopped : .failed, engine: .rclone,
                              snapshot: TransferSnapshot(), started: started, message: failure)
            }
            let threshold = task.options.deleteThresholdPercent
            if case .blocked(let percent, let deletions, let existing) = guardResult.verdict {
                return result(
                    status: .blocked, engine: .rclone, snapshot: TransferSnapshot(), started: started,
                    message: Self.blockedMessage(percent: percent, deletions: deletions, existing: existing, threshold: threshold)
                )
            }
            options.maxDeleteCount = DeleteGuard.maxDeleteCount(existing: guardResult.existing, thresholdPercent: threshold)
        }

        let command = try RcloneCommandBuilder.command(for: task, run: options)
        let tracker = SafeTracker(now: configuration.now, fileInfo: { _ in (0, false) })
        tracker.perform { $0.start() }
        control.setHooks(pause: { tracker.perform { $0.pause() } }, resume: { tracker.perform { $0.resume() } })

        onUpdate(.phase(.running))
        let log = RunLog()
        let lastStats = Locked<RcloneStats?>(nil)
        let process = try ProcessRunner.spawn(executable: rclone, arguments: command.arguments) { output in
            onUpdate(.line(output.text))
            log.noteSignal(in: output.text)
            guard let event = RcloneOutputParser.parse(line: output.text) else { return }
            switch event {
            case .stats(let stats):
                lastStats.set(stats)
                onUpdate(.snapshot(tracker.perform { tracker -> TransferSnapshot in
                    tracker.apply(stats)
                    return tracker.snapshot()
                }))
            case .error(let text): log.addError(text)
            case .notice: break
            }
        }
        control.registerMain(process)
        let code = await process.waitForExit()
        control.clearMain()

        var status: RunStatus
        var message: String?
        if control.stopRequested {
            status = .stopped
        } else if log.signal == .safetyAbort {
            status = .blocked
            message = (log.signalText.flatMap(Self.messageText(fromJSONLine:)) ?? "Trop de suppressions.") + " Rien n'a été modifié."
        } else if log.signal == .quotaReached || code == 8 {
            status = .quotaReached
            message = "Quota de transfert atteint : la copie reprendra à la prochaine exécution."
        } else if code == 0 {
            status = .succeeded
        } else if log.signal == .needsResync {
            status = .failed
            message = "bisync demande une réinitialisation de cette tâche (--resync) : l'état des deux côtés n'est plus cohérent."
        } else {
            status = .failed
            message = log.lastError ?? "rclone a échoué (code \(code))."
        }

        if status == .succeeded, !dryRun {
            if let cleanup = RcloneCommandBuilder.retentionCleanupCommand(for: task, run: options) {
                _ = try await collect(cleanup)
            }
            if task.options.verifyAfterCopy, task.mode == .copy || task.mode == .mirror {
                onUpdate(.phase(.verifying))
                var checked = task
                checked.mode = .verify
                let verification = try await collect(try RcloneCommandBuilder.command(for: checked, run: options))
                let differences = VerifyParser.rcloneDifferences(in: verification.output, includeMissingOnSource: false)
                if !differences.isEmpty {
                    status = .failed
                    message = "\(differences.count) fichier(s) diffèrent après la copie (par exemple « \(differences[0]) »)."
                }
            }
        }

        let snapshot = tracker.perform { tracker -> TransferSnapshot in
            if status == .succeeded { tracker.finish() } else { tracker.pause() }
            return tracker.snapshot()
        }
        onUpdate(.snapshot(snapshot))
        let stats = lastStats.get()
        return result(status: status, engine: .rclone, snapshot: snapshot, started: started,
                      deletions: stats?.deletes ?? 0, errors: max(log.errors, stats?.errors ?? 0), message: message)
    }

    /// bisync a déjà fait sa première exécution s'il a laissé des listes (`*.lst`) dans son dossier d'état.
    static func hasBisyncState(at directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasSuffix(".lst") }
    }

    private static func messageText(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["msg"] as? String
    }

    private struct MirrorGuardResult {
        var verdict: GuardVerdict = .allowed
        var existing = 0
        var failure: String?
    }

    /// Compte les fichiers de la destination (`rclone size`) et les suppressions prévues (simulation).
    private func mirrorGuard(_ task: SyncTask, options: RunOptions) async throws -> MirrorGuardResult {
        let size = try await collect(RcloneCommandBuilder.sizeCommand(for: task.destination, task: task, run: options))
        let existing = size.code == 0 ? (RcloneSizeParser.count(from: size.output) ?? 0) : 0   // destination absente = vide

        var simulated = options
        simulated.dryRun = true
        let dry = try await collect(try RcloneCommandBuilder.command(for: task, run: simulated))
        if control.stopRequested { return MirrorGuardResult(failure: "Arrêté.") }
        let events = (dry.errors + "\n" + dry.output).split(separator: "\n").compactMap { RcloneOutputParser.parse(line: String($0)) }
        guard dry.code == 0 else {
            let reason = events.compactMap { event -> String? in
                if case .error(let text) = event { return text }
                return nil
            }.last
            return MirrorGuardResult(failure: reason ?? "La simulation a échoué (code \(dry.code)).")
        }
        let deletions = events.compactMap { event -> Int? in
            if case .stats(let stats) = event { return stats.deletes }
            return nil
        }.last ?? 0
        let verdict = DeleteGuard.verdict(deletions: deletions, existing: existing, thresholdPercent: task.options.deleteThresholdPercent)
        return MirrorGuardResult(verdict: verdict, existing: existing)
    }

    private func verifyWithRclone(
        _ task: SyncTask, options: RunOptions, started: Date, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        onUpdate(.phase(.verifying))
        let outcome = try await collect(try RcloneCommandBuilder.command(for: task, run: options))
        if control.stopRequested { return result(status: .stopped, engine: .rclone, snapshot: TransferSnapshot(), started: started) }
        let differences = VerifyParser.rcloneDifferences(in: outcome.output)
        guard outcome.code == 0 || outcome.code == 1 else {
            return result(status: .failed, engine: .rclone, snapshot: TransferSnapshot(), started: started,
                          message: "La vérification a échoué (code \(outcome.code)).")
        }
        return result(
            status: differences.isEmpty ? .succeeded : .failed, engine: .rclone, snapshot: TransferSnapshot(),
            started: started,
            message: differences.isEmpty ? "Aucune différence." : "\(differences.count) fichier(s) diffèrent (par exemple « \(differences[0]) »)."
        )
    }
}
