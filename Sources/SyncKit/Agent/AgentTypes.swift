import Foundation

public struct AgentConfiguration: Sendable {
    public var maxParallel = 2
    /// Délai avant une nouvelle tentative après un échec.
    public var retryDelay: TimeInterval = 3600
    public var maxAttempts = 3
    /// Un intervalle entre deux évaluations plus long que cela signifie que le Mac a dormi.
    public var wakeGap: TimeInterval = 150
    /// Attente après un réveil avant de lancer le rattrapage (le réseau doit revenir).
    public var wakeHold: TimeInterval = 60
    /// Même attente au démarrage de l'agent.
    public var startupHold: TimeInterval = 60
    public var historyRetentionDays = 90

    public init() {}
}

public protocol SystemConditions: Sendable {
    func isOnACPower() -> Bool
    func isNetworkAvailable() -> Bool
    /// Le dossier ou le volume existe ; pour un service en ligne : le réseau est disponible.
    func isReachable(_ endpoint: Endpoint) -> Bool
}

public protocol AgentNotifier: Sendable {
    func notify(title: String, body: String)
}

/// Empêche la mise en veille tant qu'une exécution est en cours.
public protocol ActivityHolding: Sendable {
    func begin()
    func end()
}

public enum AgentError: Error, Codable, Equatable, Sendable, LocalizedError {
    case unknownTask
    case notRunning
    case alreadyRunning
    case globallyPaused
    case notAwaitingApproval
    case versionMismatch(agent: Int, client: Int)
    case internalFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTask: return "Tâche inconnue."
        case .notRunning: return "Cette tâche n'est pas en cours d'exécution."
        case .alreadyRunning: return "Cette tâche est déjà en cours ou en file d'attente."
        case .globallyPaused: return "L'agent est en pause globale."
        case .notAwaitingApproval: return "Cette tâche n'attend aucune validation."
        case .versionMismatch(let agent, let client):
            return "Versions incompatibles (agent \(agent), outil \(client)) : mettez à jour l'agent ou l'application."
        case .internalFailure(let message): return "Erreur interne de l'agent : \(message)"
        }
    }
}

public enum TaskRunState: Codable, Equatable, Sendable {
    case idle
    case queued
    case running
    case paused
    case waiting(reason: String)
    case awaitingApproval
    case disabled
}

public struct AgentTaskInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: TaskRunState
    public var nextDue: Date?
    public var lastRun: RunRecord?
    public var progress: ProgressInfo?

    public init(
        id: UUID, name: String, state: TaskRunState, nextDue: Date? = nil, lastRun: RunRecord? = nil,
        progress: ProgressInfo? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.nextDue = nextDue
        self.lastRun = lastRun
        self.progress = progress
    }
}

public struct AgentStatus: Codable, Equatable, Sendable {
    public var globalPause: Bool
    /// Vrai si le fichier d'état était illisible : l'agent est reparti en pause.
    public var stateRecovered: Bool
    public var taskLoadError: String?
    public var tasks: [AgentTaskInfo]

    public init(globalPause: Bool, stateRecovered: Bool, taskLoadError: String?, tasks: [AgentTaskInfo]) {
        self.globalPause = globalPause
        self.stateRecovered = stateRecovered
        self.taskLoadError = taskLoadError
        self.tasks = tasks
    }
}

/// Avancement d'une exécution, sous une forme qui traverse XPC.
public struct ProgressInfo: Codable, Equatable, Sendable {
    public var currentName: String?
    public var currentBytes: Int64
    public var currentSize: Int64
    public var currentSpeed: Double
    public var doneBytes: Int64
    public var totalBytes: Int64?
    public var filesDone: Int
    public var totalFiles: Int?
    public var overallPercent: Int?
    public var totalETA: TimeInterval?
    public var activeTime: TimeInterval

    public init(_ snapshot: TransferSnapshot) {
        currentName = snapshot.currentName
        currentBytes = snapshot.currentBytes
        currentSize = snapshot.currentSize
        currentSpeed = snapshot.currentSpeed
        doneBytes = snapshot.doneBytes
        totalBytes = snapshot.totalBytes
        filesDone = snapshot.filesDone
        totalFiles = snapshot.totalFiles
        overallPercent = snapshot.overallPercent
        totalETA = snapshot.totalETA
        activeTime = snapshot.activeTime
    }
}

public enum AgentEvent: Codable, Equatable, Sendable {
    case taskStarted(UUID)
    case progress(UUID, ProgressInfo)
    case taskFinished(UUID, RunStatus, String?)
    /// Pause globale, file d'attente ou liste de tâches modifiée : relire `status`.
    case stateChanged
}
