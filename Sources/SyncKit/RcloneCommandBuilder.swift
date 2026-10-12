import Foundation

/// Transforme une tâche en arguments rclone.
public enum RcloneCommandBuilder {
    private static let loggingFlags = [
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
            args = ["copy", source, destination] + loggingFlags
        case .mirror, .versioned:
            args = ["sync", source, destination] + loggingFlags
                + ["--backup-dir", archiveRoot(task.destination), "--exclude", archiveFilter]
            if let maxDelete = run.maxDeleteCount { args += ["--max-delete", String(maxDelete)] }
        case .move:
            args = ["move", source, destination, "--delete-empty-src-dirs"] + loggingFlags
        case .bidirectional:
            args = ["bisync", source, destination] + loggingFlags + [
                "--resilient", "--recover",
                "--conflict-resolve", "newer",
                "--max-delete", String(task.options.deleteThresholdPercent),
                "--backup-dir1", archiveRoot(task.source),
                "--backup-dir2", archiveRoot(task.destination),
                "--exclude", archiveFilter,
            ]
            if let workdir = run.bisyncWorkdir { args += ["--workdir", workdir] }
            if run.resync { args.append("--resync") }
        case .verify:
            args = ["check", source, destination, "--combined", "-"]
        }

        if let limit = task.options.bandwidthLimitKBps, task.mode != .verify {
            args += ["--bwlimit", "\(limit)K"]
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

    /// Compte les fichiers d'un côté (`rclone size --json`) : sert à calculer le pourcentage de suppressions.
    public static func sizeCommand(for endpoint: Endpoint, run: RunOptions) -> EngineCommand {
        var args = ["size", "--json", endpoint.rcloneSpec]
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
        guard task.mode != .verify else {
            return task.options.excludes.flatMap { ["--exclude", $0] }
        }
        var args = task.options.excludes.flatMap { ["--filter", "- \($0)"] }
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
