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
                              message: "Le calcul préalable a échoué : impossible de vérifier les suppressions."
                                + (RsyncCommandBuilder.ssh(task).map { " Vérifiez la connexion SSH (« ssh \($0.target) » dans le Terminal)." } ?? ""))
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

        // 1.7.8 : un seul parcours avant la copie. Le calcul préalable donne la taille de chaque fichier à copier : il
        // sert à la fois au total (progression connue dès le départ) et aux fichiers vides à protéger. Avant, une passe
        // séparée cherchait les fichiers vides puis un calcul tournait en même temps que la copie : trois parcours.
        var protectedEmpty: [String] = []
        if [.copy, .mirror, .move].contains(task.mode) {
            if knownPlan == nil {
                onUpdate(.phase(.planning))
                knownPlan = try await rsyncPlan(task, runOptions)
                if control.stopRequested { return result(status: .stopped, engine: .rsync, snapshot: TransferSnapshot(), started: started) }
                if knownPlan == nil {
                    onUpdate(.line("Calcul préalable impossible : pas de protection des fichiers vides pour cette exécution."))
                }
            }
            let empty = knownPlan.map { plan in plan.files.filter { $0.value == 0 }.map(\.key).sorted() } ?? []
            protectedEmpty = EmptySourceGuard.protectedPaths(
                sourceEmpty: empty, destinationSizes: EmptySourceGuard.sizes(of: empty, in: destination)
            )
            runOptions.excludeFrom = EmptySourceGuard.excludeFile(protectedEmpty, escape: EmptySourceGuard.rsyncEscape,
                                                                  bothForms: RsyncCommandBuilder.ssh(task) != nil)
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

        // Sans plan connu (autres modes, ou calcul préalable impossible), le total se calcule en arrière-plan.
        if knownPlan == nil && ![.copy, .mirror, .move].contains(task.mode) {
            let planOptions = runOptions   // copie immuable : Swift 5.10 refuse une `var` capturée dans une closure concurrente
            Task.detached { [self] in
                guard let plan = try? await self.rsyncPlan(task, planOptions), !self.control.stopRequested else { return }
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
        let deferred = Locked(false)
        // Un changement arrivé moins de 5 s après une relance n'est pas perdu : la relance est différée, et lit alors la
        // limite la plus récente.
        control.setBandwidthHook { _ in
            let wait = 5 - Date().timeIntervalSince(lastRestart.get())
            if wait <= 0 {
                lastRestart.set(Date())
                control.requestRestart()
                return
            }
            var schedule = false
            deferred.update { if !$0 { $0 = true; schedule = true } }
            guard schedule else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                deferred.set(false)
                lastRestart.set(Date())
                control.requestRestart()
            }
        }
        var code: Int32 = 0   // toujours donné par la boucle ; Swift 5.10 ne le voit pas à travers `while true`
        var attemptNumber = 0
        while true {
            var current = runOptions
            current.bandwidth = control.bandwidth
            // Chaque relance archive dans son propre dossier : la version d'avant, déjà archivée par la première tentative,
            // n'est jamais remplacée par un fichier à moitié réécrit.
            if attemptNumber > 0 { current.archiveStamp = "\(stamp)-r\(attemptNumber + 1)" }
            attemptNumber += 1
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
        control.allowAuxiliary()   // 1.8.3 : la vérification après copie vient après

        var status: RunStatus
        var message: String?
        if control.stopRequested {
            status = .stopped
        } else if code == 0 || code == 24 {
            status = .succeeded
        } else {
            status = .failed
            let detail = log.mainError ?? "rsync a échoué (code \(code))."
            message = RsyncCommandBuilder.ssh(task).flatMap { SSHAccess.failureMessage(code: code, access: $0) }
                .map { "\($0) Détail : \(detail)" } ?? detail
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
        // 1.8.3 : taille des fichiers mis de côté dans l'archive (rsync n'écrit pas celle des fichiers qu'il retire).
        if task.mode == .mirror, status == .succeeded {
            let root = Endpoint.join(destination, task.options.archiveFolder)
            for (path, size) in Self.localArchiveSizes(root: root, stamp: stamp) {
                onUpdate(.detail(RunDetailRow(action: .archived, size: size, path: path, origin: .destination)))
            }
        }
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
