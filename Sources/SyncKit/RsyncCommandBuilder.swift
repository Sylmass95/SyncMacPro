import Foundation

/// Transforme une tâche en arguments rsync.
public enum RsyncCommandBuilder {
    /// `--out-format=%i|%n` : rsync indique lui-même si un fichier est nouveau (`>f+++++++++`) ou mis à jour.
    /// Pas de `--timeout` : rsync compare l'horloge murale à sa dernière entrée/sortie, donc une pause
    /// (SIGSTOP) plus longue que le délai ferait échouer la copie à la reprise. La détection d'un moteur
    /// bloqué revient à l'agent (« pas de progression pendant N minutes »).
    private static let transferFlags = [
        "-rtv", "--inplace", "--partial", "--progress", "--out-format=%i|%n",
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
        args += task.options.excludes.map { "--exclude=\($0)" }
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("-n") }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// `--bwlimit` de rsync (Kio/s) : un seul débit, le plus bas des deux côtés.
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
        var args = ["-rtn", "--stats", "--out-format=%l|%n"]
        if task.mode == .mirror {
            args += ["--delete", "--exclude=/\(task.options.archiveFolder)/"]
        }
        args += task.options.excludes.map { "--exclude=\($0)" }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// Sources (le contenu du dossier, ou chaque élément choisi), destination et dossier de destination.
    private static func paths(for task: SyncTask) throws -> (sources: [String], destination: String, folder: String) {
        guard let source = task.source.filesystemPath, let destination = task.destination.filesystemPath else {
            throw CommandError.missingFilesystemPath
        }
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
