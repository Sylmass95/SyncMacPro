import Foundation

/// Ce que l'agent demande pour gérer les connexions ; un faux le remplace dans les tests de l'agent.
public protocol RemoteConfiguring: Sendable {
    func listRemotes() async throws -> [RemoteInfo]
    func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome
    func cancelConfiguration(_ name: String)
    func cancelAll()
    /// Oublie une annulation demandée avant le démarrage de rclone (l'étape est terminée).
    func forgetCancellation(_ name: String)
    /// Attend que plus aucune configuration ne tourne (arrêt de l'agent).
    func waitForIdle() async
    func delete(_ name: String) async throws
    func test(_ name: String) async -> RemoteTestResult
    func folders(remote: String, path: String) async throws -> [String]
}

/// Dialogue avec rclone par son protocole non interactif. Toute écriture de la configuration passe par rclone.
public final class RcloneConfigurator: RemoteConfiguring, @unchecked Sendable {
    let rclonePath: String
    let configPath: String?
    let configureTimeout: TimeInterval
    let listTimeout: TimeInterval
    /// Test d'une connexion : le premier appel à Google Drive (rafraîchissement du jeton) peut dépasser 30 s.
    let testTimeout: TimeInterval
    /// Faux : rclone ne peut pas ouvrir le navigateur (tests) ; il attend quand même la réponse.
    let openBrowser: Bool
    private let lock = NSLock()
    private var running: [String: RunningProcess] = [:]
    private var cancelled: Set<String> = []
    /// Annulations reçues avant que rclone soit lancé : appliquées dès son lancement.
    private var pendingCancels: Set<String> = []

    public init(
        rclonePath: String, configPath: String?, configureTimeout: TimeInterval = 600, listTimeout: TimeInterval = 30, testTimeout: TimeInterval = 60,
        openBrowser: Bool = true
    ) {
        self.rclonePath = rclonePath
        self.configPath = configPath
        self.configureTimeout = configureTimeout
        self.listTimeout = listTimeout
        self.testTimeout = testTimeout
        self.openBrowser = openBrowser
    }

    struct Output {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    /// Lance rclone et attend sa fin ; `key` permet de l'annuler ; au-delà du délai, il est arrêté.
    func run(
        _ arguments: [String], timeout: TimeInterval, key: String? = nil, onTimeout: RemoteConfigError = .noAnswer
    ) async throws -> Output {
        let collected = Locked<(out: [String], err: [String])>(([], []))
        // Sans navigateur (tests) : rclone ouvre la page avec « open » trouvé dans le PATH ; un PATH vide l'en empêche
        // sans rien changer d'autre (rclone n'a besoin d'aucun autre programme).
        var environment: [String: String]?
        if !openBrowser {
            var values = ProcessInfo.processInfo.environment
            values["PATH"] = "/var/empty"
            environment = values
        }
        let process = try ProcessRunner.spawn(executable: rclonePath, arguments: arguments, environment: environment) { line in
            collected.update { value in
                if line.stream == .stdout { value.out.append(line.text) } else { value.err.append(line.text) }
            }
        }
        if let key {
            let cancelNow: Bool = lock.withLock {
                running[key] = process
                cancelled.remove(key)
                guard pendingCancels.remove(key) != nil else { return false }
                cancelled.insert(key)
                return true
            }
            if cancelNow { process.terminate(killAfter: 2) }
        }
        let timedOut = Locked(false)
        let timer = DispatchWorkItem {
            timedOut.set(true)
            process.terminate(killAfter: 2)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let code = await process.waitForExit()
        timer.cancel()
        var wasCancelled = false
        if let key {
            lock.withLock {
                running[key] = nil
                wasCancelled = cancelled.remove(key) != nil
            }
        }
        if wasCancelled { throw RemoteConfigError.cancelled }
        if timedOut.get() { throw onTimeout }
        let value = collected.get()
        return Output(code: code, stdout: value.out.joined(separator: "\n"), stderr: value.err.joined(separator: "\n"))
    }

    /// Dernière ligne utile de rclone, sans horodatage, niveau ni enveloppes techniques (« lsjson with 2 errors… »,
    /// code HTTP) : on garde la cause (« InvalidAccessKeyId: … », « directory not found »).
    static func message(_ stderr: String) -> String {
        var line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        for marker in ["CRITICAL: ", "ERROR : ", "ERROR: ", "NOTICE: "] {
            if let range = line.range(of: marker) { line = String(line[range.upperBound...]) }
        }
        for marker in ["api error ", "last error was: ", "error in ListJSON: "] {
            if let range = line.range(of: marker, options: .backwards) { line = String(line[range.upperBound...]) }
        }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "rclone a échoué." : line
    }

    public func listRemotes() async throws -> [RemoteInfo] {
        let output = try await run(RcloneConfigCommand.listRemotes(config: configPath), timeout: listTimeout)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
        return try RcloneConfigReply.remotes(from: Data(output.stdout.utf8))
    }

    public func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        let arguments = RcloneConfigCommand.arguments(for: step, config: configPath)
        let output = try await run(arguments, timeout: configureTimeout, key: step.name, onTimeout: .timedOut)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
        return try RcloneConfigReply.outcome(from: Data(output.stdout.utf8))
    }

    public func cancelConfiguration(_ name: String) {
        let process: RunningProcess? = lock.withLock {
            guard let process = running[name] else {
                pendingCancels.insert(name)   // rclone pas encore lancé : on l'arrêtera dès son lancement
                return nil
            }
            cancelled.insert(name)
            return process
        }
        process?.terminate(killAfter: 2)
    }

    public func forgetCancellation(_ name: String) {
        _ = lock.withLock { pendingCancels.remove(name) }
    }

    public func cancelAll() {
        let names = lock.withLock { Array(running.keys) }
        names.forEach(cancelConfiguration)
    }

    public func waitForIdle() async {
        for _ in 0..<200 {   // 10 s au plus : un rclone arrêté rend la main en moins de 2 s
            if lock.withLock({ running.isEmpty }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    public func delete(_ name: String) async throws {
        let output = try await run(RcloneConfigCommand.delete(name, config: configPath), timeout: listTimeout)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
    }

    public func test(_ name: String) async -> RemoteTestResult {
        do {
            let output = try await run(RcloneConfigCommand.test(name, config: configPath), timeout: testTimeout)
            return output.code == 0 ? RemoteTestResult(ok: true) : RemoteTestResult(ok: false, message: Self.message(output.stderr))
        } catch {
            return RemoteTestResult(ok: false, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func folders(remote: String, path: String) async throws -> [String] {
        let output = try await run(RcloneConfigCommand.folders(remote: remote, path: path, config: configPath), timeout: listTimeout)
        guard output.code == 0 else { throw RemoteConfigError.rclone(Self.message(output.stderr)) }
        return try RcloneConfigReply.folders(from: Data(output.stdout.utf8))
    }
}
