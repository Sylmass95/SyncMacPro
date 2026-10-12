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

    public init(
        rsyncPath: String? = nil,
        rclonePath: String? = nil,
        rcloneConfigPath: String? = nil,
        workDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        sampleInterval: TimeInterval = 0.25
    ) {
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
}

public struct RunResult: Equatable, Sendable {
    public var status: RunStatus
    public var engine: EngineKind
    public var summary: RunSummary
    public var snapshot: TransferSnapshot
}

public enum RunnerError: Error, Equatable {
    case binaryMissing(EngineKind)
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
    private var stopRequestedFlag = false
    private var pausedFlag = false
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

    func reset() {
        lock.lock(); defer { lock.unlock() }
        main = nil
        auxiliary = []
        stopRequestedFlag = false
        pausedFlag = false
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
        if stopRequestedFlag { process.terminate() }
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
        auxiliary.forEach { $0.terminate() }
        auxiliary = []
    }
}

/// Texte collecté pendant l'exécution d'un moteur (dernières erreurs, compteurs).
final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errorLines: [String] = []
    private var errorCount = 0
    private var deletionCount = 0
    private var signalValue: OutputSignal?
    private var signalLine: String?

    func addError(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        errorCount += 1
        errorLines.append(line)
        if errorLines.count > 20 { errorLines.removeFirst() }
    }

    func addDeletion() { lock.lock(); deletionCount += 1; lock.unlock() }

    func noteSignal(in line: String) {
        guard let found = OutputSignal.detect(in: line) else { return }
        lock.lock(); defer { lock.unlock() }
        if signalValue == nil || found == .safetyAbort { signalValue = found; signalLine = line }
    }

    var errors: Int { lock.lock(); defer { lock.unlock() }; return errorCount }
    var deletions: Int { lock.lock(); defer { lock.unlock() }; return deletionCount }
    var signal: OutputSignal? { lock.lock(); defer { lock.unlock() }; return signalValue }
    var signalText: String? { lock.lock(); defer { lock.unlock() }; return signalLine }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return errorLines.last }
}

/// Valeur partagée entre threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    func get() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}
