import Foundation

public struct RunnerConfiguration: Sendable {
    public var rsyncPath: String?
    public var rclonePath: String?
    /// Fichier de configuration rclone (`--config`) ; `nil` = celui de l'utilisateur.
    public var rcloneConfigPath: String?
    /// Dossier d'état propre aux tâches (bisync y garde ses listes).
    public var workDirectory: URL
    public var now: @Sendable () -> Date
    /// Intervalle entre deux mesures de progression.
    public var sampleInterval: TimeInterval
    /// rsync sans sortie ni calcul pendant ce délai (secondes) : il est arrêté et l'exécution échoue (nouvel essai
    /// plus tard). 0 : pas de surveillance.
    public var stallTimeout: TimeInterval
    public var stallCheckInterval: TimeInterval
    /// Sonde d'accès lancée avant le moteur sur chaque dossier (programme, arguments) ; voir `TaskRunner.probeAccess`.
    public var accessProbe: @Sendable (String) -> (String, [String]) = RunnerConfiguration.defaultAccessProbe
    /// Au-delà, le dossier est déclaré sans réponse (autorisation de macOS en attente, disque ou NAS figé).
    public var accessProbeTimeout: TimeInterval = 15
    /// Montage des partages réseau non montés (1.6.5) et délai d'un montage.
    public var shares: ShareMounting = NetFSShareMounter()
    public var shareMountTimeout: TimeInterval = 60
    /// Pendant la copie, le partage est revérifié à cet intervalle : démonté, la copie s'arrête (1.6.8).
    public var shareWatchInterval: TimeInterval = 30
    /// 1.8.12 : mot de passe d'un partage SMB (trousseau, pour l'agent) : la connexion directe au NAS sans rien configurer.
    /// `nil` : seules les connexions créées à la main servent.
    public var smbPassword: (@Sendable (SMBShare) -> String?)?

    public static let defaultStallTimeout: TimeInterval = 20 * 60
    /// Lister un dossier : un instant d'ordinaire, et macOS y demande l'autorisation d'un dossier protégé.
    public static let defaultAccessProbe: @Sendable (String) -> (String, [String]) = { ("/bin/ls", ["-f", $0]) }

    public init(
        rsyncPath: String? = nil,
        rclonePath: String? = nil,
        rcloneConfigPath: String? = nil,
        workDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        sampleInterval: TimeInterval = 0.25,
        stallTimeout: TimeInterval = RunnerConfiguration.defaultStallTimeout,
        stallCheckInterval: TimeInterval = 30
    ) {
        self.stallTimeout = stallTimeout
        self.stallCheckInterval = stallCheckInterval
        self.rsyncPath = rsyncPath
        self.rclonePath = rclonePath
        self.rcloneConfigPath = rcloneConfigPath
        self.workDirectory = workDirectory
        self.now = now
        self.sampleInterval = sampleInterval
    }
}

public enum RunPhase: Equatable, Sendable {
    case preparing
    /// Simulation préalable (garde-fous, calcul du total).
    case planning
    case running
    case verifying
}

public enum RunUpdate: Sendable {
    case phase(RunPhase)
    case snapshot(TransferSnapshot)
    /// Une ligne de la sortie du moteur (pour le journal).
    case line(String)
    /// 1.8.3 : un détail qui n'est pas dans la sortie du moteur (taille d'un fichier mis dans l'archive).
    case detail(RunDetailRow)
}

public struct RunResult: Equatable, Sendable {
    public var status: RunStatus
    public var engine: EngineKind
    public var summary: RunSummary
    public var snapshot: TransferSnapshot
    /// Un nouvel essai a-t-il une chance de réussir ? Faux pour une vérification qui a trouvé des différences :
    /// relancer ne changerait rien. Vrai pour une panne (disque absent, réseau coupé).
    public var retryable: Bool = true
    /// Partage réseau injoignable (nom du partage) : l'agent fait attendre la tâche au lieu d'un échec (1.6.5).
    public var shareUnavailable: String? = nil
    /// Le partage était là au départ et a disparu pendant la copie (1.6.8) : l'attente part de maintenant.
    public var shareLostDuringRun: Bool = false
    /// Le service en ligne refuse les envois (quota du jour atteint, 1.8.8) : l'agent fait attendre le compte.
    public var uploadLimitReached: Bool = false
}

public enum RunnerError: Error, Equatable, LocalizedError {
    case binaryMissing(EngineKind)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(.rsync):
            return "rsync 3 est introuvable. L'outil rsync de macOS (openrsync) ne convient pas : "
                + "installez rsync 3 avec « brew install rsync »."
        case .binaryMissing(.rclone):
            return "rclone est introuvable : installez-le avec « brew install rclone »."
        }
    }
}

/// Accès thread-safe au suivi de progression (alimenté par plusieurs threads).
final class SafeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let tracker: ProgressTracker

    init(now: @escaping () -> Date, fileInfo: @escaping (String) -> (size: Int64, live: Bool)) {
        tracker = ProgressTracker(now: now, fileInfo: fileInfo)
    }

    func perform<T>(_ body: (ProgressTracker) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(tracker)
    }
}

/// Pause, reprise et arrêt d'une exécution, vus depuis n'importe quel thread.
final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var main: RunningProcess?
    private var auxiliary: [RunningProcess] = []
    /// Posé par `stopAuxiliary` : un processus annexe lancé après coup est arrêté dès son départ.
    private var auxiliaryStopped = false
    private var stopRequestedFlag = false
    private var pausedFlag = false
    private var stalledFor: TimeInterval?
    private var bandwidthValue = BandwidthRate.unlimited
    private var restartFlag = false
    /// Appelé (hors verrou) quand la limite change pendant l'exécution : le moteur l'applique à chaud.
    private var bandwidthHook: (@Sendable (BandwidthRate) -> Void)?
    /// Appelés (hors verrou) quand l'exécution est mise en pause ou reprise : arrêtent / relancent le chronomètre.
    private var pauseHook: (@Sendable () -> Void)?
    private var resumeHook: (@Sendable () -> Void)?

    func setHooks(pause: @escaping @Sendable () -> Void, resume: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        pauseHook = pause
        resumeHook = resume
    }

    var stopRequested: Bool { lock.lock(); defer { lock.unlock() }; return stopRequestedFlag }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pausedFlag }
    /// Délai au bout duquel un processus a été arrêté parce qu'il ne progressait plus (`nil` : jamais).
    var stalledAfter: TimeInterval? { lock.lock(); defer { lock.unlock() }; return stalledFor }
    func markStalled(after timeout: TimeInterval) { lock.lock(); stalledFor = timeout; lock.unlock() }

    var bandwidth: BandwidthRate { lock.lock(); defer { lock.unlock() }; return bandwidthValue }

    func setBandwidth(_ rate: BandwidthRate) {
        lock.lock()
        let changed = rate != bandwidthValue
        bandwidthValue = rate
        let hook = bandwidthHook
        lock.unlock()
        if changed { hook?(rate) }
    }

    /// rsync : arrête le processus principal pour qu'il soit relancé aussitôt (nouvelle limite de débit).
    func requestRestart() {
        lock.lock(); defer { lock.unlock() }
        guard !stopRequestedFlag, let main else { return }
        restartFlag = true
        main.terminate()
    }

    /// Vrai une fois si une relance a été demandée.
    func consumeRestart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = restartFlag
        restartFlag = false
        return value
    }

    func setBandwidthHook(_ hook: (@Sendable (BandwidthRate) -> Void)?) {
        lock.lock(); bandwidthHook = hook; lock.unlock()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        main = nil
        auxiliary = []
        auxiliaryStopped = false
        stopRequestedFlag = false
        pausedFlag = false
        stalledFor = nil
        restartFlag = false
        bandwidthHook = nil
        pauseHook = nil
        resumeHook = nil
    }

    func registerMain(_ process: RunningProcess) {
        lock.lock(); defer { lock.unlock() }
        main = process
        if stopRequestedFlag { process.terminate() } else if pausedFlag { process.pause() }
    }

    func registerAuxiliary(_ process: RunningProcess) {
        lock.lock(); defer { lock.unlock() }
        auxiliary.append(process)
        if stopRequestedFlag || auxiliaryStopped { process.terminate() }
    }

    func clearMain() { lock.lock(); main = nil; lock.unlock() }

    func pause() {
        lock.lock()
        pausedFlag = true
        main?.pause()
        let hook = pauseHook
        lock.unlock()
        hook?()
    }

    func resume() {
        lock.lock()
        pausedFlag = false
        main?.resume()
        let hook = resumeHook
        lock.unlock()
        hook?()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopRequestedFlag = true
        pausedFlag = false
        main?.terminate()
        auxiliary.forEach { $0.terminate() }
    }

    /// Arrête les processus annexes (calcul du total) quand la copie principale est finie.
    func stopAuxiliary() {
        lock.lock(); defer { lock.unlock() }
        auxiliaryStopped = true
        auxiliary.forEach { $0.terminate() }
        auxiliary = []
    }

    /// 1.8.3 : après la copie, les annexes de comptage sont arrêtées ; ce qui suit (vérification, réparation, liste de
    /// l'archive) doit pouvoir démarrer.
    func allowAuxiliary() {
        lock.lock(); defer { lock.unlock() }
        auxiliaryStopped = false
    }
}

/// Texte collecté pendant l'exécution d'un moteur (dernières erreurs, compteurs).
final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    /// Les premières erreurs : la cause vient avant ses conséquences (voir `EngineErrorText`).
    private var firstErrors: [String] = []
    private var errorCount = 0
    private var distinctErrors: Set<String> = []
    private var deletionCount = 0
    private var signalValue: OutputSignal?
    private var signalLine: String?

    func addError(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        errorCount += 1
        if firstErrors.count < 20 { firstErrors.append(line) }
        // Un même incident revient à chaque tentative, et les lignes de résumé le rappellent : compté une fois.
        if !EngineErrorText.isConsequence(line) { distinctErrors.insert(line) }
    }

    func addDeletion() { lock.lock(); deletionCount += 1; lock.unlock() }

    func noteSignal(in line: String) {
        guard let found = OutputSignal.detect(in: line) else { return }
        lock.lock(); defer { lock.unlock() }
        if signalValue == nil || found == .safetyAbort { signalValue = found; signalLine = line }
    }

    /// Erreurs distinctes ; au moins 1 s'il n'y a eu que des lignes de résumé.
    var errors: Int {
        lock.lock(); defer { lock.unlock() }
        return max(distinctErrors.count, errorCount > 0 ? 1 : 0)
    }
    var deletions: Int { lock.lock(); defer { lock.unlock() }; return deletionCount }
    var signal: OutputSignal? { lock.lock(); defer { lock.unlock() }; return signalValue }
    var signalText: String? { lock.lock(); defer { lock.unlock() }; return signalLine }
    /// Message d'échec : la première cause, expliquée.
    var mainError: String? {
        lock.lock(); defer { lock.unlock() }
        return EngineErrorText.summary(errors: firstErrors, total: max(distinctErrors.count, errorCount > 0 ? 1 : 0))
    }
}

/// Valeur partagée entre threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    func get() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    /// Lire puis modifier sous le même verrou (un `get` suivi d'un `set` perdrait les écritures concurrentes).
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
