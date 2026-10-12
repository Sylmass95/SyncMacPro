import Foundation

/// Transforme une tâche en arguments rsync.
public enum RsyncCommandBuilder {
    /// `--out-format=%i|%n` : rsync indique lui-même si un fichier est nouveau (`>f+++++++++`) ou mis à jour.
    private static let transferFlags = [
        "-rtv", "--inplace", "--partial", "--progress", "--timeout=60", "--out-format=%i|%n",
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

        if let limit = task.options.bandwidthLimitKBps, task.mode != .verify {
            args.append("--bwlimit=\(limit)")
        }
        args += task.options.excludes.map { "--exclude=\($0)" }
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("-n") }
        args += sources + [destination]
        return EngineCommand(engine: .rsync, arguments: args)
    }

    /// Simulation qui liste ce qui serait copié (`taille|nom`) et les suppressions, avec les statistiques.
    public static func planCommand(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let (sources, destination, _) = try paths(for: task)
        if task.mode.requiresRclone || task.mode == .verify {
            throw CommandError.unsupportedMode(mode: task.mode, engine: .rsync)
        }
        var args = ["-rtn", "--stats", "--out-format=%l|%n", "--timeout=60"]
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
