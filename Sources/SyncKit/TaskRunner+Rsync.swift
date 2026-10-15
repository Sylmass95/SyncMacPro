import Foundation

extension TaskRunner {
    func runRsync(
        _ task: SyncTask, dryRun: Bool, stamp: String, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        let rsync = try executable(for: .rsync)
        let started = configuration.now()
        var runOptions = RunOptions(dryRun: dryRun, archiveStamp: stamp)
        onUpdate(.phase(.preparing))

        if task.mode == .verify {
            return try await verifyWithRsync(task, options: runOptions, started: started, onUpdate: onUpdate)
        }
        _ = try RsyncCommandBuilder.command(for: task, run: runOptions)   // refuse tôt les modes non pris en charge
        let source = task.source.filesystemPath ?? ""
        let destination = task.destination.filesystemPath ?? ""

        // Simulation : le plan répond à « qu'est-ce qui serait fait ? ».
        if dryRun {
            onUpdate(.phase(.planning))
            guard let plan = try await rsyncPlan(task, runOptions, strict: true) else {
                if control.stopRequested {
                    return result(status: .stopped, engine: .rsync, snapshot: TransferSnapshot(), started: started)
                }
                return result(status: .failed, engine: .rsync, snapshot: TransferSnapshot(), started: started,
                              message: "La simulation a échoué (source introuvable ou illisible ?).")
            }
            var snapshot = TransferSnapshot()
            snapshot.totalFiles = plan.files.count
            snapshot.totalBytes = plan.totalBytes
            var outcome = result(
                status: control.stopRequested ? .stopped : .succeeded, engine: .rsync, snapshot: snapshot,
                started: started, deletions: plan.deletions.count,
                message: "Simulation : \(plan.files.count) fichier(s) à copier, \(plan.deletions.count) suppression(s)."
            )
            outcome.summary.filesTransferred = plan.files.count
            outcome.summary.bytesTransferred = plan.totalBytes
            return outcome
        }

        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        // Garde-fou du miroir : on calcule d'abord, avant de toucher à quoi que ce soit.
        var knownPlan: RsyncPlan?
        if task.mode == .mirror {
            onUpdate(.phase(.planning))
            guard let plan = try await rsyncPlan(task, runOptions) else {
                if control.stopRequested {
                    return result(status: .stopped, engine: .rsync, snapshot: TransferSnapshot(), started: started)
                }
                return result(status: .failed, engine: .rsync, snapshot: TransferSnapshot(), started: started,
                              message: "Le calcul préalable a échoué : impossible de vérifier les suppressions.")
            }
            let threshold = task.options.deleteThresholdPercent
            if case .blocked(let percent, let deletions, let existing) = DeleteGuard.verdict(for: plan, thresholdPercent: threshold) {
                return result(
                    status: .blocked, engine: .rsync, snapshot: TransferSnapshot(), started: started, deletions: 0,
                    message: Self.blockedMessage(percent: percent, deletions: deletions, existing: existing, threshold: threshold)
                )
            }
            knownPlan = plan
        }

        // Fichiers vides à la source qui écraseraient une version non vide : exclus de l'exécution.
        var protectedEmpty: [String] = []
        if [.copy, .mirror, .move].contains(task.mode) {
            let empty = EmptySourceGuard.emptyFiles(in: source, items: task.sourceItems)
            protectedEmpty = EmptySourceGuard.protectedPaths(
                sourceEmpty: empty, destinationSizes: EmptySourceGuard.sizes(of: empty, in: destination)
            )
            runOptions.excludeFrom = EmptySourceGuard.excludeFile(protectedEmpty, escape: EmptySourceGuard.rsyncEscape)
            protectedEmpty.forEach { onUpdate(.line("Fichier vide à la source, non copié (la destination a une version non vide) : \($0)")) }
        }
        defer { if let file = runOptions.excludeFrom { try? FileManager.default.removeItem(atPath: file) } }

        let tracker = SafeTracker(now: configuration.now, fileInfo: { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: Endpoint.join(source, name))[.size] as? NSNumber)?
                .flatMap { $0 }?.int64Value ?? 0
            return (size, !FileManager.default.fileExists(atPath: Endpoint.join(destination, name)))
        })
        tracker.perform { $0.start() }
        control.setHooks(pause: { tracker.perform { $0.pause() } }, resume: { tracker.perform { $0.resume() } })
        if let plan = knownPlan { tracker.perform { $0.setPlan(files: plan.files, directories: plan.directories) } }

        // Sans plan connu, le total se calcule en arrière-plan : la copie démarre tout de suite.
        if knownPlan == nil {
            Task.detached { [self] in
                guard let plan = try? await self.rsyncPlan(task, runOptions), !self.control.stopRequested else { return }
                tracker.perform { $0.setPlan(files: plan.files, directories: plan.directories) }
            }
        }

        onUpdate(.phase(.running))
        let log = RunLog()
        let lastStarted = Locked<String?>(nil)
        let interval = configuration.sampleInterval
        let sampler = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if let name = lastStarted.get(),
                   let size = (try? FileManager.default.attributesOfItem(atPath: Endpoint.join(destination, name))[.size] as? NSNumber)?.flatMap({ $0 })?.int64Value {
                    tracker.perform { $0.observeCurrentFileBytes(size) }
                }
                onUpdate(.snapshot(tracker.perform { $0.snapshot() }))
            }
        }

        // rsync ne change pas sa limite en route : une nouvelle limite l'arrête et il est relancé aussitôt ; avec
        // `--partial --inplace` il reprend où il en était. Au plus une relance toutes les 5 s. Le plan et le garde-fou
        // du miroir ne sont pas refaits.
        let control = self.control
        let lastRestart = Locked(Date.distantPast)
        control.setBandwidthHook { _ in
            guard Date().timeIntervalSince(lastRestart.get()) > 5 else { return }
            lastRestart.set(Date())
            control.requestRestart()
        }
        var code: Int32
        while true {
            var current = runOptions
            current.bandwidth = control.bandwidth
            let attempt = try RsyncCommandBuilder.command(for: task, run: current)
            let watch = makeWatch(for: .rsync)
            // Les erreurs d'une tentative arrêtée pour relance (« received SIGTERM ») ne comptent pas.
            let attemptErrors = Locked<[String]>([])
            let process = try ProcessRunner.spawn(executable: rsync, arguments: attempt.arguments) { output in
                watch.note()
                onUpdate(.line(output.text))
                guard let event = RsyncOutputParser.parse(line: output.text) else { return }
                switch event {
                case .fileStarted(let name, _): lastStarted.set(name)
                case .deleting: log.addDeletion()
                case .error(let text): attemptErrors.update { $0.append(text) }
                default: break
                }
                tracker.perform { $0.apply(event) }
            }
            control.registerMain(process)
            watch.attach(process)
            code = await process.waitForExit()
            watch.stop()
            control.clearMain()
            guard control.consumeRestart(), !control.stopRequested else {
                attemptErrors.get().forEach(log.addError)
                break
            }
            onUpdate(.line("Limite de débit modifiée : rsync est relancé et reprend où il en était."))
        }
        control.setBandwidthHook(nil)
        sampler.cancel()
        control.stopAuxiliary()

        var status: RunStatus
        var message: String?
        if control.stopRequested {
            status = .stopped
        } else if code == 0 || code == 24 {
            status = .succeeded
        } else {
            status = .failed
            message = log.mainError ?? "rsync a échoué (code \(code))."
        }

        if status == .succeeded, task.options.verifyAfterCopy, task.mode == .copy || task.mode == .mirror {
            onUpdate(.phase(.verifying))
            var checked = task
            checked.mode = .verify
            let verification = try await collect(try RsyncCommandBuilder.command(for: checked, run: runOptions))
            let differences = VerifyParser.rsyncDifferences(in: verification.output)
            if !differences.isEmpty {
                status = .failed
                message = "\(differences.count) fichier(s) diffèrent après la copie (par exemple « \(differences[0]) »)."
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
        return result(status: status, engine: .rsync, snapshot: snapshot, started: started,
                      deletions: log.deletions, errors: log.errors, message: message)
    }

    /// Simulation (`-n --stats`) ; `nil` si rsync a échoué ou a été arrêté.
    /// `strict` : seuls les codes 0 et 24 comptent. Le garde-fou d'un miroir tolère aussi 23 (erreurs d'entrée/sortie :
    /// rsync saute alors les suppressions, c'est le sens sûr) ; une simulation demandée par l'utilisateur, non :
    /// elle dirait « rien à copier » pour une source introuvable.
    func rsyncPlan(_ task: SyncTask, _ options: RunOptions, strict: Bool = false) async throws -> RsyncPlan? {
        let plan = Locked(RsyncPlan())
        let code = try await stream(try RsyncCommandBuilder.planCommand(for: task, run: options)) { line in
            plan.update { RsyncPlanParser.add(line, to: &$0) }
        }
        guard code == 0 || code == 24 || (!strict && code == 23) else { return nil }
        return plan.get()
    }

    private func verifyWithRsync(
        _ task: SyncTask, options: RunOptions, started: Date, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        onUpdate(.phase(.verifying))
        let outcome = try await collect(try RsyncCommandBuilder.command(for: task, run: options))
        if control.stopRequested { return result(status: .stopped, engine: .rsync, snapshot: TransferSnapshot(), started: started) }
        guard outcome.code == 0 || outcome.code == 24 else {
            return result(status: .failed, engine: .rsync, snapshot: TransferSnapshot(), started: started,
                          message: "La vérification a échoué (code \(outcome.code)) : source introuvable ou illisible ?")
        }
        let differences = VerifyParser.rsyncDifferences(in: outcome.output)
        return result(
            status: differences.isEmpty ? .succeeded : .failed, engine: .rsync, snapshot: TransferSnapshot(),
            started: started,
            message: differences.isEmpty ? "Aucune différence." : "\(differences.count) fichier(s) diffèrent (par exemple « \(differences[0]) »).",
            retryable: differences.isEmpty
        )
    }
}
