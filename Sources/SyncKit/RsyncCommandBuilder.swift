import Foundation

/// Transforme une tâche en arguments rsync.
public enum RsyncCommandBuilder {
    /// `--out-format=%i|%l|%n` : rsync indique lui-même si un fichier est nouveau (`>f+++++++++`) ou mis à jour, et
    /// sa taille (1.8.2 : détails de l'exécution).
    /// Pas de `--timeout` : rsync compare l'horloge murale à sa dernière entrée/sortie, donc une pause
    /// (SIGSTOP) plus longue que le délai ferait échouer la copie à la reprise. La détection d'un moteur
    /// bloqué revient à l'agent (« pas de progression pendant N minutes »).
    private static let transferFlags = [
        "-rtv", "--inplace", "--partial", "--progress", "--out-format=%i|%l|%n",
    ]

    /// Commande d'exécution (ou de simulation si `run.dryRun`).
    public static func command(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let (sources, destination, destinationFolder) = try paths(for: task)
        var args: [String]

        switch task.mode {
        case .copy:
            args = transferFlags
        case .mirror:
            let archive = "\(PathText.withoutTrailingSlash(destinationFolder))/\(task.options.archiveFolder)/\(run.archiveStamp)"
            args = transferFlags + [
                "--delete", "--backup", "--backup-dir=\(archive)",
                "--exclude=/\(task.options.archiveFolder)/",
            ]
        case .move:
            args = transferFlags + ["--remove-source-files"]
        case .verify:
            args = ["-rcn", "--out-format=%i|%n"]
        case .bidirectional, .versioned:
            throw CommandError.unsupportedMode(mode: task.mode, engine: .rsync)
        }

        if task.mode != .verify {
            if let rate = run.bandwidth, let kbps = bwlimitKBps(rate) {
                args.append("--bwlimit=\(kbps)")
            } else if let limit = task.options.bandwidthLimitKBps {
                args.append("--bwlimit=\(limit)")
            }
        }
        if let file = run.excludeFrom { args.append("--exclude-from=\(file)") }
        if task.mode != .verify { args += timeTolerance(task) }
        args += ssh(task)?.rsyncArguments ?? []
        args += excludes(task).map { "--exclude=\($0)" }
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("-n") }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// `--bwlimit` de rsync (Kio/s) : un seul débit, le plus bas des deux côtés.
    /// Partage réseau en source ou en destination : une seconde d'écart sur les dates est tolérée (1.7.2). Le partage
    /// garde les dates moins finement que le Mac, et rsync réécrivait sinon la date de chaque fichier à chaque passage.
    static func timeTolerance(_ task: SyncTask) -> [String] {
        let network = [task.source, task.destination].contains { if case .network = $0 { return true }; return false }
        return network ? ["--modify-window=1"] : []
    }

    public static func bwlimitKBps(_ rate: BandwidthRate) -> Int? {
        let sides = [rate.upBytesPerSecond, rate.downBytesPerSecond].compactMap { $0 }
        guard let lowest = sides.min() else { return nil }
        return Int(max(1, lowest / 1024))
    }

    /// Simulation qui liste ce qui serait copié (`taille|nom`) et les suppressions, avec les statistiques.
    public static func planCommand(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let (sources, destination, _) = try paths(for: task)
        if task.mode.requiresRclone || task.mode == .verify {
            throw CommandError.unsupportedMode(mode: task.mode, engine: .rsync)
        }
        var args = ["-rtn", "--stats", "--out-format=%l|%n"] + timeTolerance(task) + (ssh(task)?.rsyncArguments ?? [])
        if task.mode == .mirror {
            args += ["--delete", "--exclude=/\(task.options.archiveFolder)/"]
        }
        args += excludes(task).map { "--exclude=\($0)" }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// Accès SSH utilisable : complet, un seul côté sur un partage réseau (rsync ne relie pas deux machines distantes),
    /// et ce partage est bien celui de l'accès.
    static func ssh(_ task: SyncTask) -> SSHAccess? {
        guard let access = task.sshAccess, access.isComplete else { return nil }
        let networkSides = [task.source, task.destination].filter { if case .network = $0 { return true }; return false }
        guard networkSides.count == 1, access.remotePath(for: networkSides[0]) != nil else { return nil }
        return access
    }

    /// Exclusions de l'utilisateur ; par SSH, chacune sous ses deux formes Unicode (rsync ne les convertit pas).
    static func excludes(_ task: SyncTask) -> [String] {
        ssh(task) == nil ? task.options.excludes : SSHAccess.bothForms(task.options.excludes)
    }

    /// Sources (le contenu du dossier, ou chaque élément choisi), destination et dossier de destination. Avec SSH
    /// (1.8.1), le côté réseau devient `utilisateur@serveur:/chemin` et le dossier de destination est celui du NAS.
    private static func paths(for task: SyncTask) throws -> (sources: [String], destination: String, folder: String) {
        guard var source = task.source.filesystemPath, var destination = task.destination.filesystemPath else {
            throw CommandError.missingFilesystemPath
        }
        var sourcePrefix = "", destinationPrefix = ""
        if let access = ssh(task) {
            if let remote = access.remotePath(for: task.source) { source = remote; sourcePrefix = "\(access.target):" }
            if let remote = access.remotePath(for: task.destination) { destination = remote; destinationPrefix = "\(access.target):" }
        }
        let (sources, target, folder) = try localPaths(task, source: source, destination: destination)
        return (sources.map { sourcePrefix + $0 }, destinationPrefix + target, folder)
    }

    private static func localPaths(_ task: SyncTask, source: String, destination: String) throws -> (sources: [String], destination: String, folder: String) {
        let sources: [String]
        if task.sourceItems.isEmpty {
            sources = [PathText.withTrailingSlash(source)]
        } else {
            // Sans « / » final : un dossier est copié en tant que dossier.
            sources = task.sourceItems.map {
                PathText.withoutTrailingSlash(Endpoint.join(source, $0))
            }
        }
        return (sources, PathText.withTrailingSlash(destination), destination)
    }
}
