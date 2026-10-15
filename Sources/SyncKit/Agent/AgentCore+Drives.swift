import Foundation

/// Sauvegarde sur disque amovible (1.4.0) : départ au branchement, suspension au débranchement, reprise ou nouvelle
/// exécution au rebranchement, éjection.
extension AgentCore {
    /// Attente après le branchement : le disque finit de se monter (Spotlight, vérification du volume).
    public static let driveSettleDelay: TimeInterval = 5

    /// Appelé par le moniteur à chaque montage ou démontage, et au démarrage de l'agent.
    public func drivesChanged() {
        guard let drives else { return }
        let now = clock.now()
        let current = drives.mountedVolumes()
        for uuid in current.keys where mountedDrives[uuid] == nil { mountSeen[uuid] = now }
        for uuid in mountedDrives.keys where current[uuid] == nil {
            mountSeen[uuid] = nil
            // Débranché en pleine exécution : le moteur est arrêté, `finish` suspend l'exécution.
            for (id, job) in jobs where job.task.removableDrive?.volumeUUID == uuid {
                jobs[id]?.driveLost = true
                job.runner.stop()
            }
        }
        mountedDrives = current
        handleDrives(now)
        emit(.stateChanged)
    }

    /// Volumes branchés depuis 5 s : reprise d'une exécution suspendue, ou nouvelle sauvegarde selon le déclencheur.
    func handleDrives(_ now: Date) {
        guard drives != nil, !state.paused, !shuttingDown else { return }
        for task in tasks where task.isEnabled {
            // Deux exécutions au plus : le branchement attend une place (rappelé à la fin de chaque exécution).
            guard jobs.count < configuration.maxParallel else { return }
            guard let drive = task.removableDrive, mountedDrives[drive.volumeUUID] != nil,
                  let seen = mountSeen[drive.volumeUUID], now.timeIntervalSince(seen) >= Self.driveSettleDelay,
                  jobs[task.id] == nil, !queue.contains(where: { $0.id == task.id }) else { continue }
            let key = task.id.uuidString
            var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
            // `lastMountHandled` : l'instant où le branchement servi a été vu ; un même branchement n'est servi qu'une fois.
            if let handled = entry.lastMountHandled, handled >= seen { continue }
            if let reason = unmetCondition(task, now: now) {
                waiting[task.id] = reason   // secteur, plage horaire : on réessaie au prochain passage
                continue
            }
            entry.lastMountHandled = seen
            if let suspended = entry.suspendedRun {
                entry.suspendedRun = nil
                state.tasks[key] = entry
                if now.timeIntervalSince(suspended.since) <= Double(drive.resumeWindowDays) * 86_400 {
                    startJob(task, overrideGuard: false, resuming: suspended)
                    continue
                }
                close(suspended, message: "Interrompue : disque débranché plus de \(drive.resumeWindowDays) jour(s).", at: now)
            }
            state.tasks[key] = entry
            let due: Bool
            switch drive.trigger {
            case .everyConnection: due = true
            case .atMostEveryDays(let days):
                due = entry.lastSuccess.map { now.timeIntervalSince($0) >= Double(days) * 86_400 } ?? true
            }
            if due { startJob(task, overrideGuard: false) } else { persist() }
        }
    }

    /// Tâche liée à un disque qui n'est pas branché (toujours faux sans moniteur de disques).
    func driveMissing(_ task: SyncTask) -> Bool {
        guard let drive = task.removableDrive, drives != nil else { return false }
        return mountedDrives[drive.volumeUUID] == nil
    }

    /// La tâche avec sa destination sur le point de montage actuel du volume (inchangée sans disque amovible).
    func resolvedForDrive(_ task: SyncTask) -> SyncTask {
        guard let drive = task.removableDrive, let mount = mountedDrives[drive.volumeUUID] else { return task }
        var resolved = task
        resolved.destination = .local(path: drive.destinationPath(mountPath: mount))
        return resolved
    }

    /// Point de montage actuel, relu à l'instant (l'avis de démontage peut arriver après l'erreur du moteur).
    func currentMountPath(_ drive: RemovableDrive) -> String? {
        guard let drives else { return mountedDrives[drive.volumeUUID] }
        return drives.mountedVolumes()[drive.volumeUUID]
    }

    /// Exécution interrompue par le débranchement : ni échec ni nouvel essai ; elle attend le disque.
    func suspendForDrive(_ job: Job, drive: RemovableDrive, summary: RunSummary, now: Date) {
        var record = job.record
        var paused = summary
        paused.message = "En pause : disque débranché."
        record.status = .interrupted
        record.summary = paused
        record.finishedAt = now
        try? history.save(record)
        job.logWriter?.append("En pause : disque « \(drive.volumeName) » débranché.", force: true)
        job.logWriter?.close()
        let key = job.task.id.uuidString
        var entry = state.tasks[key] ?? TaskScheduleState(firstSeen: now)
        entry.runningSince = nil
        entry.retryAt = nil
        entry.attempts = 0
        // L'erreur d'entrée/sortie du débranchement n'est pas une erreur de la sauvegarde : pas reportée sur le bilan final.
        var done = summary
        done.errors = 0
        entry.suspendedRun = SuspendedRun(recordID: record.id, since: now, summary: done)
        state.tasks[key] = entry
        persist()
        if job.task.notifications != .never {
            notifier.notify(
                title: "\(job.task.name) : en pause",
                body: "Disque « \(drive.volumeName) » débranché : la sauvegarde reprendra quand vous le rebrancherez."
            )
        }
        emit(.taskFinished(job.task.id, .interrupted, paused.message))
        afterJob(job.task.id)
    }

    /// Fin commune d'une exécution (activité, observateurs, place libérée, file).
    func afterJob(_ id: UUID) {
        refreshActivity()
        emit(.stateChanged)
        startQueued()
        if userQueueCurrent == id && !shuttingDown { userQueueCurrent = nil; persist() }
        advanceUserQueue()
        handleDrives(clock.now())
    }

    func close(_ suspended: SuspendedRun, message: String, at now: Date) {
        guard var record = try? history.record(id: suspended.recordID) else { return }
        var summary = suspended.summary
        summary.message = message
        record.status = .interrupted
        record.summary = summary
        record.finishedAt = record.finishedAt ?? now
        try? history.save(record)
    }

    /// « Abandonner » : l'exécution suspendue est close, la prochaine sauvegarde repartira de zéro.
    public func abandonSuspended(_ id: UUID) throws {
        let key = id.uuidString
        guard let suspended = state.tasks[key]?.suspendedRun else { throw AgentError.notRunning }
        close(suspended, message: "Abandonnée : disque débranché.", at: clock.now())
        state.tasks[key]?.suspendedRun = nil
        persist()
        emit(.stateChanged)
    }

    /// Bouton « Éjecter ».
    public func ejectDrive(_ id: UUID) async throws {
        guard let task = tasks.first(where: { $0.id == id }), let drive = task.removableDrive else { throw AgentError.unknownTask }
        guard let drives, let mount = mountedDrives[drive.volumeUUID] else { throw AgentError.driveNotConnected(drive.volumeName) }
        guard !jobs.values.contains(where: { $0.task.removableDrive?.volumeUUID == drive.volumeUUID }) else {
            throw AgentError.alreadyRunning
        }
        if let refusal = await drives.eject(mountPath: mount) {
            throw AgentError.ejectRefused(refusal)
        }
        drivesChanged()
    }

    /// Réussite d'une sauvegarde sur disque : éjection automatique si demandée et si rien d'autre n'écrit sur le
    /// disque, sinon notification « vous pouvez éjecter ».
    func finishedOnDrive(_ task: SyncTask, drive: RemovableDrive, summary: RunSummary) {
        let othersOnDrive = jobs.values.contains { $0.task.removableDrive?.volumeUUID == drive.volumeUUID }
        guard drive.eject == .automatic, !othersOnDrive, let drives, let mount = mountedDrives[drive.volumeUUID] else {
            notify(task, .succeeded, summary, note: othersOnDrive ? nil : "vous pouvez éjecter « \(drive.volumeName) ».")
            return
        }
        let id = task.id
        ejectTasks[id] = Task { [weak self] in
            let refusal = await drives.eject(mountPath: mount)
            await self?.autoEjected(task, drive: drive, summary: summary, refusal: refusal)
        }
    }

    func autoEjected(_ task: SyncTask, drive: RemovableDrive, summary: RunSummary, refusal: String?) {
        ejectTasks[task.id] = nil
        if let refusal {
            log("éjection de « \(drive.volumeName) » refusée : \(refusal)")
            // Un refus est un incident : signalé même quand seules les erreurs sont notifiées.
            if task.notifications != .never {
                notifier.notify(title: "\(task.name) : terminée",
                                body: "Le disque « \(drive.volumeName) » n'a pas pu être éjecté : \(refusal)")
            }
        } else {
            notify(task, .succeeded, summary, note: "disque « \(drive.volumeName) » éjecté.")
        }
        drivesChanged()
    }

    /// Bilan cumulé d'une exécution reprise.
    static func combine(_ first: RunSummary, _ second: RunSummary) -> RunSummary {
        let duration = first.durationSeconds + second.durationSeconds
        let bytes = first.bytesTransferred + second.bytesTransferred
        return RunSummary(
            filesTransferred: first.filesTransferred + second.filesTransferred, bytesTransferred: bytes,
            deletions: first.deletions + second.deletions, errors: first.errors + second.errors,
            durationSeconds: duration, message: second.message,
            directories: second.directories ?? first.directories,
            averageSpeed: duration > 0 && bytes > 0 ? Double(bytes) / duration : second.averageSpeed
        )
    }

    /// « 2 h », « 3 j », « 12 min ».
    static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400)) j" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600)) h" }
        return "\(max(1, Int(seconds / 60))) min"
    }
}
