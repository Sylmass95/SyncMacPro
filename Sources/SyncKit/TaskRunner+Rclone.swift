import Foundation

extension TaskRunner {
    /// `forceResync` : réinitialisation de bisync demandée par une exécution précédente (voir plus bas).
    func runRclone(
        _ task: SyncTask, dryRun: Bool, stamp: String, onUpdate: @escaping @Sendable (RunUpdate) -> Void,
        forceResync: Bool = false
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
            (options.bisyncPath1, options.bisyncPath2) = try Self.bisyncLinks(for: task, in: configuration.workDirectory)
            options.resync = forceResync || !Self.hasBisyncState(at: workdir)     // première exécution : initialisation
            // bisync refuse un côté qui n'existe pas : la destination d'une nouvelle tâche est créée, comme le font la
            // copie et le miroir. La source, jamais : absente, c'est un disque débranché.
            if options.resync && !dryRun {
                if let path = task.destination.filesystemPath {
                    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                } else {
                    _ = try? await collect(RcloneCommandBuilder.mkdirCommand(for: task.destination, run: options))
                }
            }
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

        // Fichiers vides à la source qui écraseraient une version non vide : exclus de l'exécution.
        var protectedEmpty: [String] = []
        if !dryRun, [.copy, .mirror, .versioned, .move, .bidirectional].contains(task.mode) {
            protectedEmpty = await protectedEmptyFiles(task, options: options, onUpdate: onUpdate)
            // 1.8.2 : la synchronisation bidirectionnelle copie dans les deux sens ; un fichier protégé est exclu des deux
            // côtés et reste tel quel (essai réel BTS : un .MP4 de 700 Mo remplacé par sa copie vide du Drive).
            if task.mode == .bidirectional {
                var reverse = task
                (reverse.source, reverse.destination) = (task.destination, task.source)
                protectedEmpty = Array(Set(protectedEmpty + (await protectedEmptyFiles(reverse, options: options, onUpdate: onUpdate)))).sorted()
            }
            options.excludeFrom = EmptySourceGuard.excludeFile(protectedEmpty, escape: EmptySourceGuard.rcloneEscape)
            protectedEmpty.forEach { onUpdate(.line("Fichier vide à la source, non copié (la destination a une version non vide) : \($0)")) }
        }
        defer { if let file = options.excludeFrom { try? FileManager.default.removeItem(atPath: file) } }

        // Dossiers à faire : une simulation en arrière-plan liste les fichiers à copier (la copie démarre tout de suite).
        let directories = Locked<RcloneDirectoryProgress?>(nil)
        let copiedEarly = Locked<[String]>([])   // fichiers copiés avant la fin du comptage
        let countsDirectories = !dryRun && [.copy, .mirror, .versioned, .move].contains(task.mode)
        var counting: Task<Void, Never>?
        if countsDirectories {
            var simulated = options
            simulated.dryRun = true
            simulated.rcSocketPath = nil
            let planCommand = try RcloneCommandBuilder.command(for: task, run: simulated)
            let pending = Locked<Set<String>>([])
            let control = self.control
            counting = Task.detached { [self] in
                let code = try? await self.stream(planCommand, errors: { line in
                    pending.update { RcloneDirectoryProgress.notePending(line, into: &$0) }
                }) { line in pending.update { RcloneDirectoryProgress.notePending(line, into: &$0) } }
                guard code == 0, !control.stopRequested else { return }
                directories.update { current in
                    // Fichiers copiés pendant le comptage (même verrou que la copie) : comptés et faits.
                    current = RcloneDirectoryProgress(pendingFiles: pending.get(), alreadyCopied: copiedEarly.get())
                }
            }
        }

        // Limite de départ, et prise de contrôle pour la changer en route (pas pour une simulation).
        options.bandwidth = control.bandwidth
        let socket = dryRun ? nil : RcloneRemoteControl.socketPath()
        options.rcSocketPath = socket
        defer { if let socket { try? FileManager.default.removeItem(atPath: socket) } }
        let command = try RcloneCommandBuilder.command(for: task, run: options)
        let tracker = SafeTracker(now: configuration.now, fileInfo: { _ in (0, false) })
        tracker.perform { $0.start() }
        control.setHooks(pause: { tracker.perform { $0.pause() } }, resume: { tracker.perform { $0.resume() } })

        onUpdate(.phase(.running))
        let log = RunLog()
        let lastStats = Locked<RcloneStats?>(nil)
        let process = try ProcessRunner.spawn(
            executable: rclone, arguments: command.arguments) { output in
            onUpdate(.line(output.text))
            log.noteSignal(in: output.text)
            guard let event = RcloneOutputParser.parse(line: output.text) else { return }
            switch event {
            case .stats(let stats):
                lastStats.set(stats)
                let dirs = directories.get()
                onUpdate(.snapshot(tracker.perform { tracker -> TransferSnapshot in
                    tracker.apply(stats)
                    if let dirs { tracker.setRcloneDirectories(done: dirs.done, total: dirs.total) }
                    return tracker.snapshot()
                }))
            case .error(let text): log.addError(text)
            case .notice: break
            case .copied(let name):
                directories.update { current in
                    if current != nil { current?.fileCopied(name) } else { copiedEarly.update { $0.append(name) } }
                }
            }
        }
        control.registerMain(process)
        if let socket {
            let sender = LatestRateSender { rate in await RcloneRemoteControl.setRate(rclone: rclone, socket: socket, rate: rate) }
            control.setBandwidthHook { sender.submit($0) }
        }
        let code = await process.waitForExit()
        control.setBandwidthHook(nil)
        control.clearMain()
        // Le comptage des dossiers finit d'ordinaire bien avant la copie ; sur un petit dossier, on l'attend.
        // Copie finie (réussie ou arrêtée) : le comptage des dossiers n'a plus d'intérêt, il ne retarde pas la fin.
        control.stopAuxiliary()
        await counting?.value
        // Comptage interrompu (copie plus rapide que lui) : une copie réussie a fait tous les dossiers qu'elle a touchés.
        if countsDirectories, code == 0, !control.stopRequested {
            directories.update { current in
                if current == nil { current = RcloneDirectoryProgress(pendingFiles: [], alreadyCopied: copiedEarly.get()) }
            }
        }
        if let dirs = directories.get() {
            tracker.perform { $0.setRcloneDirectories(done: dirs.done, total: dirs.total) }
        }

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
        } else if log.signal == .needsResync, task.mode == .bidirectional, !dryRun, !forceResync {
            // bisync s'arrête dès que ses listes ne correspondent plus aux deux côtés (changement de casse seul sur un
            // disque qui ignore la casse, exécution interrompue au mauvais moment…) et exige une réinitialisation.
            // Elle n'arrivait qu'au nouvel essai, une heure plus tard, après une notification d'échec : on la fait tout
            // de suite. Une réinitialisation ne supprime rien et garde la version la plus récente de chaque fichier ; la
            // version remplacée va dans l'archive.
            onUpdate(.line("Réinitialisation automatique de bisync (rien n'est supprimé, les versions remplacées sont archivées)."))
            var again = try await runRclone(task, dryRun: false, stamp: stamp, onUpdate: onUpdate, forceResync: true)
            if again.status == .succeeded {
                again.summary.message = "bisync a été réinitialisé automatiquement après une incohérence : les deux côtés "
                    + "ont été réunis (version la plus récente gardée, versions remplacées dans \(task.options.archiveFolder) ; "
                    + "un fichier supprimé d'un seul côté a pu réapparaître)."
            }
            return again
        } else if log.signal == .needsResync {
            status = .failed
            message = "bisync demande une réinitialisation de cette tâche (--resync) : l'état des deux côtés n'est plus cohérent."
        } else {
            status = .failed
            message = log.mainError ?? "rclone a échoué (code \(code))."
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

        if status == .succeeded, message == nil, !protectedEmpty.isEmpty {
            message = EmptySourceGuard.message(count: protectedEmpty.count)
        }
        let snapshot = tracker.perform { tracker -> TransferSnapshot in
            if status == .succeeded { tracker.finish() } else { tracker.pause() }
            return tracker.snapshot()
        }
        onUpdate(.snapshot(snapshot))
        let stats = lastStats.get()
        // L'état n'est marqué « liens courts » qu'après une vraie exécution réussie : une simulation ou un premier essai
        // raté laisserait sinon croire à rclone que les anciennes listes sont les bonnes.
        if task.mode == .bidirectional, !dryRun, status == .succeeded, let workdir = options.bisyncWorkdir {
            try? Data().write(to: URL(fileURLWithPath: workdir).appendingPathComponent(Self.bisyncLinksMarker))
        }
        return result(status: status, engine: .rclone, snapshot: snapshot, started: started,
                      deletions: stats?.deletes ?? 0, errors: log.errors > 0 ? log.errors : (stats?.errors ?? 0), message: message)
    }

    /// Fichiers vides de la source dont la destination a une version non vide (listes de rclone, sans rien copier).
    private func protectedEmptyFiles(
        _ task: SyncTask, options: RunOptions, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async -> [String] {
        let empty = Locked<[String]>([])
        let code = try? await stream(RcloneCommandBuilder.emptyFilesCommand(for: task, run: options)) { line in
            empty.update { $0.append(line) }
        }
        // Liste partielle (un sous-dossier illisible, une erreur passagère) : on protège quand même ce qui a été lu.
        if code != 0 { onUpdate(.line("Liste des fichiers vides incomplète (code \(code.map(String.init) ?? "?")) : protection partielle.")) }
        guard !empty.get().isEmpty else { return [] }
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("smp-liste-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        guard (try? empty.get().joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)) != nil,
              let outcome = try? await collect(RcloneCommandBuilder.destinationSizesCommand(for: task, file: list.path, run: options)),
              let entries = try? JSONSerialization.jsonObject(with: Data(outcome.output.utf8)) as? [[String: Any]]
        else { return [] }
        var sizes: [String: Int64] = [:]
        for entry in entries {
            if let path = entry["Path"] as? String, let size = (entry["Size"] as? NSNumber)?.int64Value { sizes[path] = size }
        }
        return EmptySourceGuard.protectedPaths(sourceEmpty: empty.get(), destinationSizes: sizes)
    }

    /// Marque d'un dossier d'état créé avec les liens courts (1.2.0) : les listes d'avant portent le nom des chemins
    /// réels et ne seraient pas retrouvées ; sans cette marque, une resynchronisation les remplace.
    static let bisyncLinksMarker = "liens-courts"

    /// bisync a déjà fait sa première exécution s'il a laissé des listes (`*.lst`) dans son dossier d'état.
    static func hasBisyncState(at directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains(bisyncLinksMarker) && names.contains { $0.hasSuffix(".lst") }
    }

    /// Un lien court par côté sur le disque, dans `work/bl/<12 premiers caractères de la tâche>/1` et `/2`.
    /// Un lien qui pointe déjà au bon endroit n'est pas recréé. Avec `--links` (`-l`), rclone refuse une racine qui
    /// est un lien : on garde alors les vrais chemins.
    static func bisyncLinks(for task: SyncTask, in work: URL) throws -> (String?, String?) {
        if task.options.extraArguments.contains(where: { $0 == "-l" || $0 == "--links" }) { return (nil, nil) }
        let folder = work.appendingPathComponent("bl/\(task.id.uuidString.prefix(12))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func link(_ name: String, _ endpoint: Endpoint) throws -> String? {
            guard let target = endpoint.filesystemPath else { return nil }
            let url = folder.appendingPathComponent(name)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == target { return url.path }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            return url.path
        }
        return (try link("1", task.source), try link("2", task.destination))
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
            message: differences.isEmpty ? "Aucune différence." : "\(differences.count) fichier(s) diffèrent (par exemple « \(differences[0]) »).",
            retryable: differences.isEmpty
        )
    }
}
