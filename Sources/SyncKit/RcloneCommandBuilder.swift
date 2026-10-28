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
            args = ["copy", source, destination] + verbosity(task) + loggingFlags
        case .mirror, .versioned:
            args = ["sync", source, destination] + verbosity(task) + loggingFlags
                + ["--backup-dir", archiveRoot(task.destination), "--exclude", archiveFilter]
            if let maxDelete = run.maxDeleteCount { args += ["--max-delete", String(maxDelete)] }
        case .move:
            args = ["move", source, destination, "--delete-empty-src-dirs"] + verbosity(task) + loggingFlags
        case .bidirectional:
            // bisync nomme son verrou et ses listes d'après les deux chemins : au-delà de 255 caractères il échoue.
            // Un côté sur le disque passe donc par un lien court (`run.bisyncPath1`, `run.bisyncPath2`), préparé par le runner.
            let sideA = run.bisyncPath1.map { Endpoint.local(path: $0) } ?? task.source
            let sideB = run.bisyncPath2.map { Endpoint.local(path: $0) } ?? task.destination
            // 1.8.2 : `-v` aussi, pour que le journal (et les détails) listent les fichiers copiés ou supprimés.
            args = ["bisync", sideA.rcloneSpec, sideB.rcloneSpec] + verbosity(task) + loggingFlags + [
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
        // 1.8.8 : quota du jour de Google Drive atteint, rclone s'arrête au lieu de réessayer pendant des heures.
        if task.mode != .verify, task.destination.isCloud || (task.mode == .bidirectional && task.source.isCloud) {
            args.append("--drive-stop-on-upload-limit")
        }
        if let file = run.excludeFrom, task.mode != .verify { args += ["--exclude-from", file] }
        args += filterArguments(for: task)
        if task.mode != .bidirectional { args += fastList(task.source, task.destination) }
        args += task.options.extraArguments
        if run.dryRun, task.mode != .verify { args.append("--dry-run") }
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// `-v` (lignes « Copied » pour les dossiers faits), sauf si l'utilisateur a choisi un niveau de journal : rclone refuse
    /// `-v` avec `--log-level` ou `-q`.
    static func verbosity(_ task: SyncTask) -> [String] {
        let chosen = task.options.extraArguments.contains { argument in
            ["-q", "--quiet", "-v", "-vv", "-vvv", "--verbose", "--log-level"].contains(argument) || argument.hasPrefix("--log-level=")
        }
        return chosen ? [] : ["-v"]
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
        args += fastList(endpoint)
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// 1.7.8 : sur un service en ligne (Drive…), `--fast-list` liste un dossier entier en quelques requêtes au lieu
    /// d'une par sous-dossier. Sans effet utile entre dossiers locaux ; jamais pour bisync (ses listes lui sont propres).
    static func fastList(_ endpoints: Endpoint...) -> [String] {
        endpoints.contains { $0.isCloud } ? ["--fast-list"] : []
    }

    /// Fichiers vides de la source (même sélection et mêmes exclusions que la copie), un chemin par ligne.
    public static func emptyFilesCommand(for task: SyncTask, run: RunOptions) -> EngineCommand {
        var args = ["lsf", "-R", "--files-only", "--max-size", "0", "--format", "p", task.source.rcloneSpec]
        var listing = task
        listing.mode = .copy
        args += filterArguments(for: listing)
        args += fastList(task.source)
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Tailles à la destination des chemins listés dans `file` (`lsjson --files-from`).
    /// 1.8.5 : au-delà de `onePassThreshold` fichiers, la destination est lue en une fois (`--fast-list`) au lieu d'être
    /// interrogée fichier par fichier (4 151 fichiers sur un Drive : 25 min).
    public static let onePassThreshold = 200

    public static func destinationSizesCommand(for task: SyncTask, file: String, run: RunOptions, count: Int = 0) -> EngineCommand {
        var args = ["lsjson", "-R", task.destination.rcloneSpec, "--files-from", file, "--files-only"]
        args += count > onePassThreshold ? fastList(task.destination) : ["--no-traverse"]
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// 1.8.3 : un fichier copié tel quel d'un côté à l'autre (réparation d'une copie vide).
    public static func copyToCommand(from: Endpoint, to: Endpoint, run: RunOptions) -> EngineCommand {
        var args = ["copyto", from.rcloneSpec, to.rcloneSpec]
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// 1.8.3 : tailles des fichiers d'un dossier (archive d'une exécution), `lsjson -R --files-only`.
    public static func listSizesCommand(for endpoint: Endpoint, run: RunOptions) -> EngineCommand {
        var args = ["lsjson", "-R", "--files-only", endpoint.rcloneSpec] + fastList(endpoint)
        if let config = run.rcloneConfigPath { args += ["--config", config] }
        return EngineCommand(engine: .rclone, arguments: args)
    }

    /// Comptage en arrière-plan (simulation) : tailles seulement (1.8.4). Sans cela, il relisait en même temps que la
    /// copie chaque fichier de même taille mais d'une autre date (essai réel : une vidéo de 80 Go sur un NAS par VPN).
    public static func countingCommand(for task: SyncTask, run: RunOptions) throws -> EngineCommand {
        var simulated = run
        simulated.dryRun = true
        simulated.rcSocketPath = nil
        let command = try self.command(for: task, run: simulated)
        return EngineCommand(engine: .rclone, arguments: command.arguments + ["--size-only"])
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

