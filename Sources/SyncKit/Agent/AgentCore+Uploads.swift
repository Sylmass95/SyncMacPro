import Foundation

/// Quota d'envoi des services en ligne sur 24 h glissantes, par compte (1.8.8).
extension AgentCore {
    /// Octets déjà envoyés par les copies en cours vers ce compte.
    func uploadsInFlight(_ account: String, excluding id: UUID) -> Int64 {
        jobs.values.reduce(0) { total, job in
            guard job.task.id != id, CloudUploadBudget.account(for: job.task) == account else { return total }
            return total + (job.latest?.doneBytes ?? 0)
        }
    }

    /// Date à laquelle le compte de la tâche peut de nouveau recevoir des envois ; `nil` s'il le peut déjà.
    func uploadFreeAt(_ task: SyncTask, now: Date) -> Date? {
        guard let account = CloudUploadBudget.account(for: task), let quota = task.options.maxTransferGB else { return nil }
        return CloudUploadBudget.freeAt(
            quotaGB: quota, account: state.cloudAccounts[account] ?? CloudAccountState(),
            inFlight: uploadsInFlight(account, excluding: task.id), now: now
        )
    }

    /// Raison d'attente d'une tâche dont le compte a épuisé son quota.
    func uploadWait(_ task: SyncTask, now: Date) -> String? {
        guard let account = CloudUploadBudget.account(for: task), let free = uploadFreeAt(task, now: now) else { return nil }
        return "quota d'envoi de « \(account) » atteint, reprise vers \(clockText(free, now: now))"
    }

    /// Quota de la copie qui part : le reste du compte sur 24 h. Lancée à la main sur un compte épuisé, elle garde
    /// son quota (`--max-transfer 0` ne limiterait rien) : le service dira lui-même s'il refuse.
    func cappedForUploads(_ task: SyncTask, now: Date) -> SyncTask {
        guard let account = CloudUploadBudget.account(for: task), let quota = task.options.maxTransferGB else { return task }
        let remaining = CloudUploadBudget.remainingGB(
            quotaGB: quota, account: state.cloudAccounts[account] ?? CloudAccountState(),
            inFlight: uploadsInFlight(account, excluding: task.id), now: now
        )
        guard remaining >= 1 else { return task }
        var capped = task
        capped.options.maxTransferGB = min(quota, remaining)
        return capped
    }

    /// Note les octets envoyés et un refus du service. Vrai si ce refus ne fait que répéter le précédent (rien
    /// d'envoyé depuis) : il n'est pas notifié une deuxième fois.
    func recordUploads(_ task: SyncTask, _ outcome: Result<RunResult, Error>, now: Date) -> Bool {
        guard let account = CloudUploadBudget.account(for: task), case .success(let result) = outcome else { return false }
        var cloud = state.cloudAccounts[account] ?? CloudAccountState()
        cloud.uploads = CloudUploadBudget.recent(cloud, now: now)
        let sent = result.summary.bytesTransferred
        if sent > 0 { cloud.uploads.append(CloudUpload(at: now, bytes: sent)) }
        var repeated = false
        if result.uploadLimitReached {
            repeated = cloud.blockedUntil != nil && sent == 0
            cloud.blockedUntil = now.addingTimeInterval(configuration.uploadLimitRetryDelay)
        } else if sent > 0 {
            cloud.blockedUntil = nil
        }
        state.cloudAccounts[account] = cloud
        return repeated
    }

    func clockText(_ date: Date, now: Date) -> String {
        let calendar = clock.calendar
        let time = calendar.dateComponents([.hour, .minute, .day, .month], from: date)
        let hhmm = String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return hhmm }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain \(hhmm)"
        }
        return String(format: "le %02d/%02d %@", time.day ?? 0, time.month ?? 0, hhmm)
    }
}
