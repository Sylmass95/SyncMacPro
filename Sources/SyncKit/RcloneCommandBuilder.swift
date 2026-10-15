import Foundation

/// Transforme une tâche en arguments rclone.
public enum RcloneCommandBuilder {
    private static let loggingFlags = [
        "--color", "NEVER",   // pas de codes couleur ANSI dans les messages repris par l'app
        "--use-json-log", "--stats", "1s", "--stats-log-level", "NOTICE",
        "--retries", "3", "--low-level-retries", "10",
    ]

    public static func command(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        let source = task.source.rcloneSpec
        let destination = task.destination.rcloneSpec
        let archiveRoot: (Endpoint) -> String = {
            $0.appending(task.options.archiveFolder).appending(run.archiveStamp).rcloneSpec
        }
        let archiveFilter = "/\(task.options.archiveFolder)/**"
        var args: [String]

        switch task.mode {
        case .copy:
            args = ["copy", source, destination, "-v"] + loggingFlags
        case .mirror, .versioned:
            args = ["sync", source, destination, "-v"] + loggingFlags
                + ["--backup-dir", archiveRoot(task.destination), "--exclude", archiveFilter]
            if let maxDelete = run.maxDeleteCount { args += ["--max-delete", String(maxDelete)] }
        case .move:
            args = ["move", source, destination, "--delete-empty-src-dirs", "-v"] + loggingFlags
        case .bidirectional:
            // bisync nomme son verrou et ses listes d'après les deux chemins : au-delà de 255 caractères il échoue.
            // Un côté sur le disque passe donc par un lien court (`run.bisyncPath1`, `run.bisyncPath2`), préparé par le runner.
            let sideA = run.bisyncPath1.map { Endpoint.local(path: $0) } ?? task.source
            let sideB = run.bisyncPath2.map { Endpoint.local(path: $0) } ?? task.destination
            args = ["bisync", sideA.rcloneSpec, sideB.rcloneSpec] + loggingFlags + [
                "--resilient", "--recover",
                "--conflict-resolve", "newer",
                "--max-delete", String(task.options.deleteThresholdPercent),
                "--backup-dir1", archiveRoot(sideA),
                "--backup-dir2", archiveRoot(sideB),
                "--exclude", archiveFilter,
            ]
            if let workdir = run.bisyncWorkdir { args += ["--workdir", workdir] }
            // Une resynchronisation garde la version la plus récente de chaque fichier (comme --conflict-resolve).
            if run.resync { args += ["--resync", "--resync-mode", "newer"] }
        case .verify:
            args = ["check", source, destination, "--combined", "-"]
        }

        if task.mode != .verify {
            if let rate = run.bandwidth, let value = bwlimitValue(rate) {
                args += ["--bwlimit", value]
            } else if let limit = task.options.bandwidthLimitKBps {
                args += ["--bwlimit", "\(limit)K"]
            }
            if let socket = run.rcSocketPath { args += ["--rc", "--rc-addr", "unix://\(socket)", "--rc-no-auth"] }
        }
        if let quota = task.options.maxTransferGB, task.mode != .verify {
            args += ["--max-transfer", "\(quota)G", "--cutoff-mode", "soft"]
        }
        args += filterArguments(for: task)
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("--dry-run") }
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// `--bwlimit` de rclone : « ENVOI:RÉCEPTION » en Kio/s, `off` pour un côté sans limite.
    public static func bwlimitValue(_ rate: BandwidthRate) -> String? {
        guard rate.upBytesPerSecond != nil || rate.downBytesPerSecond != nil else { return nil }
        func side(_ bytes: Int64?) -> String { bytes.map { "\(max(1, $0 / 1024))K" } ?? "off" }
        return "\(side(rate.upBytesPerSecond)):\(side(rate.downBytesPerSecond))"
    }

    /// Compte les fichiers d'un côté (`rclone size --json`) : sert à calculer le pourcentage de suppressions.
    /// Le dossier d'archive et les exclusions de l'utilisateur ne comptent pas : l'archive grossit avec le temps et
    /// ferait baisser artificiellement le pourcentage de suppressions.
    public static func sizeCommand(for endpoint: Endpoint, task: SyncTask, run: RunOptions) -> EngineCommand {
        var args = ["size", "--json", endpoint.rcloneSpec, "--exclude", "/\(task.options.archiveFolder)/**"]
        args += task.options.excludes.flatMap { ["--exclude", $0] }
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Crée un dossier distant (bisync refuse un côté absent).
    public static func mkdirCommand(for endpoint: Endpoint, run: RunOptions) -> EngineCommand {
        var args = ["mkdir", endpoint.rcloneSpec]
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Supprime les versions archivées plus anciennes que la durée de conservation (mode `versioned`).
    public static func retentionCleanupCommand(for task: SyncTask, run: RunOptions) -> EngineCommand? {
        guard task.mode == .versioned, let days = task.options.retentionDays else { return nil }
        let archive = task.destination.appending(task.options.archiveFolder).rcloneSpec
        var args = ["delete", archive, "--min-age", "\(days)d", "--rmdirs"]
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Exclusions, puis (si une sélection d'éléments est définie) uniquement ces éléments.
    private static func filterArguments(for task: SyncTask) -> [String] {
        // La vérification ignore l'archive (elle n'existe que d'un côté) et respecte la même sélection que la copie.
        var args = task.mode == .verify ? ["--filter", "- /\(task.options.archiveFolder)/**"] : []
        args += task.options.excludes.flatMap { ["--filter", "- \($0)"] }
        if !task.sourceItems.isEmpty {
            for item in task.sourceItems {
                let name = PathText.withoutTrailingSlash(item)
                args += ["--filter", "+ /\(name)", "--filter", "+ /\(name)/**"]
            }
            args += ["--filter", "- **"]
        }
        return args
    }
}

