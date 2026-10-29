import Foundation

/// 1.8.10 : ce que devient une exécution qui a buté sur des noms mal enregistrés sur le NAS.
struct SourceNameOutcome {
    var status: RunStatus
    var message: String?
    var errors: Int
    var retryable = true
}

extension TaskRunner {
    /// Après la copie : signale les doublons, rattrape par la connexion directe les fichiers que le partage monté n'a pas
    /// su ouvrir, et signale ceux qui restent. Sans nom illisible, l'issue de la copie ne change pas.
    func settleSourceNames(
        _ names: SourceNameLog, task: SyncTask, options: RunOptions, outcome: SourceNameOutcome,
        onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async -> SourceNameOutcome {
        var outcome = outcome
        let duplicates = names.duplicates, unreadable = names.unreadable
        for path in duplicates {
            onUpdate(.line(SourceNameText.duplicateLine(path)))
            onUpdate(.detail(RunDetailRow(action: .duplicate, size: nil, path: path, origin: .source)))
        }
        if !unreadable.isEmpty, outcome.status == .failed, !control.stopRequested {
            let others = max(0, outcome.errors - unreadable.count)
            unreadable.forEach { onUpdate(.line(SourceNameText.unreadableLine($0))) }
            var remaining = unreadable, reason: String?
            let share = [.copy, .mirror, .versioned].contains(task.mode) ? SMBShare.of(task.source) : nil
            let remote = share.flatMap { SMBShare.remote(for: $0, config: rcloneConfigText(options)) }
            if let share, let remote {
                onUpdate(.line("Connexion directe « \(remote) » : lecture de \(SourceNameText.files(unreadable.count)) au nom mal enregistré."))
                let copied = await copyThroughDirectConnection(unreadable, from: share.spec(remote: remote), task: task,
                                                               options: options, onUpdate: onUpdate)
                reason = copied.reason
                remaining = unreadable.filter { copied.sizes[$0] == nil }
                for path in unreadable where copied.sizes[path] != nil {
                    onUpdate(.detail(RunDetailRow(action: .recovered, size: copied.sizes[path] ?? nil, path: path, origin: .source)))
                }
            }
            remaining.forEach { onUpdate(.detail(RunDetailRow(action: .unreadable, size: nil, path: $0, origin: .source))) }
            let othersText = others > 0 ? " \(others) autre(s) erreur(s) : voir le journal." : ""
            if remaining.isEmpty {
                outcome.message = SourceNameText.recovered(unreadable.count) + othersText
                outcome.errors = others
                if others == 0 { outcome.status = .succeeded }
            } else {
                outcome.message = SourceNameText.unreadable(remaining.count, hasDirectConnection: remote != nil, reason: reason) + othersText
                outcome.errors = remaining.count + others
                // Sans connexion directe, relancer buterait sur les mêmes fichiers.
                if remote == nil, others == 0 { outcome.retryable = false }
            }
            if !duplicates.isEmpty { outcome.message = (outcome.message ?? "") + " " + SourceNameText.duplicates(duplicates.count) }
        } else if !duplicates.isEmpty, outcome.status == .succeeded {
            outcome.message = [outcome.message, SourceNameText.duplicates(duplicates.count)].compactMap { $0 }.joined(separator: " ")
        }
        return outcome
    }

    /// Copie les fichiers nommés par la connexion directe ; renvoie leur taille (chemin → taille) et la cause d'un échec.
    private func copyThroughDirectConnection(
        _ paths: [String], from spec: String, task: SyncTask, options: RunOptions,
        onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async -> (sizes: [String: Int64?], reason: String?) {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("smp-direct-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        guard (try? paths.map { SourceNameIssue.directPath($0) + "\n" }.joined().write(to: list, atomically: true, encoding: .utf8)) != nil else {
            return ([:], "liste des fichiers impossible à écrire")
        }
        var run = options
        run.bandwidth = control.bandwidth
        let command = RcloneCommandBuilder.directCopyCommand(from: spec, task: task, list: list.path, run: run)
        let sizes = Locked<[String: Int64?]>([:]), lastError = Locked<String?>(nil)
        let handle: @Sendable (String) -> Void = { line in
            onUpdate(.line(line))
            switch RcloneOutputParser.parse(line: line) {
            case .copied(let name): sizes.update { $0[name] = RunDetailParser.parse(line)?.size }
            case .error(let text): lastError.set(text)
            default: break
            }
        }
        let code = try? await stream(command, errors: handle, onOutput: handle)
        if code == nil { return (sizes.get(), "rclone introuvable") }
        return (sizes.get(), code == 0 ? nil : (lastError.get() ?? "code \(code ?? -1)"))
    }

    /// Le fichier de configuration de rclone, pour y trouver la connexion directe (type, hôte et compte seulement).
    private func rcloneConfigText(_ options: RunOptions) -> String {
        let path = options.rcloneConfigPath ?? configuration.rcloneConfigPath ?? ProcessInfo.processInfo.environment["RCLONE_CONFIG"]
            ?? (NSHomeDirectory() + "/.config/rclone/rclone.conf")
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
