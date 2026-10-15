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
    /// Dossier de travail des moteurs (état de bisync, liens courts) : nettoyé quand une tâche est supprimée.
    public var workDirectory: URL?

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
    case invalidTask(String)
    case unknownRun
    case tooManySimulations
    case remoteInUse([String])
    case invalidRemote(String)
    case remoteBusy
    case rcloneMissing
    /// La tâche n'est pas dans la file d'attente (1.4.0).
    case notInQueue
    /// Le disque amovible de la tâche n'est pas branché (1.4.0).
    case driveNotConnected(String)
    /// Le système a refusé d'éjecter le disque (fichier ouvert, Spotlight) (1.4.0).
    case ejectRefused(String)

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
        case .invalidTask(let reason): return reason
        case .unknownRun: return "Exécution inconnue."
        case .tooManySimulations: return "Deux simulations sont déjà en cours : attendez qu'elles se terminent."
        case .remoteInUse(let tasks):
            return "Cette connexion est utilisée par : \(tasks.joined(separator: ", ")). Modifiez ou supprimez ces tâches d'abord."
        case .invalidRemote(let reason): return reason
        case .remoteBusy: return "Cette connexion est déjà en cours de configuration."
        case .rcloneMissing: return "rclone est introuvable : installez-le avec « brew install rclone »."
        case .notInQueue: return "Cette tâche n'est pas dans la file."
        case .driveNotConnected(let name): return "Le disque « \(name) » n'est pas branché."
        case .ejectRefused(let reason): return "Le disque n'a pas pu être éjecté : \(reason)"
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
    /// Copie manuelle : présente le temps de son exécution, jamais enregistrée.
    public var isOneOff: Bool
    /// Place dans la file d'attente explicite (1 = la prochaine) ; `nil` hors de la file.
    public var queuePosition: Int?
    /// Disque amovible : suspendue depuis (disque débranché) ; disque branché ou non. `nil` hors disque amovible.
    public var driveSuspendedSince: Date?
    public var driveMounted: Bool?

    public init(
        id: UUID, name: String, state: TaskRunState, nextDue: Date? = nil, lastRun: RunRecord? = nil,
        progress: ProgressInfo? = nil, isOneOff: Bool = false, queuePosition: Int? = nil,
        driveSuspendedSince: Date? = nil, driveMounted: Bool? = nil
    ) {
        self.driveSuspendedSince = driveSuspendedSince
        self.driveMounted = driveMounted
        self.queuePosition = queuePosition
        self.id = id
        self.name = name
        self.state = state
        self.nextDue = nextDue
        self.lastRun = lastRun
        self.progress = progress
        self.isOneOff = isOneOff
    }
}

public struct AgentStatus: Codable, Equatable, Sendable {
    public var globalPause: Bool
    /// Vrai si le fichier d'état était illisible : l'agent est reparti en pause.
    public var stateRecovered: Bool
    public var taskLoadError: String?
    public var tasks: [AgentTaskInfo]
    /// File d'attente explicite ; `nil` pour un agent plus ancien.
    public var queue: QueueInfo?
    /// Plafonds de débit des réglages ; `nil` pour un agent plus ancien.
    public var bandwidth: BandwidthLimits?

    public init(
        globalPause: Bool, stateRecovered: Bool, taskLoadError: String?, tasks: [AgentTaskInfo],
        queue: QueueInfo? = nil, bandwidth: BandwidthLimits? = nil
    ) {
        self.queue = queue
        self.bandwidth = bandwidth
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
    /// Dossiers faits / à faire, vitesse moyenne (octets/s) : facultatifs, absents d'un agent plus ancien.
    public var dirsDone: Int?
    public var totalDirs: Int?
    public var averageSpeed: Double?

    public init(_ snapshot: TransferSnapshot) {
        dirsDone = snapshot.totalDirs == nil ? nil : snapshot.dirsDone
        totalDirs = snapshot.totalDirs
        averageSpeed = snapshot.averageSpeed > 0 ? snapshot.averageSpeed : nil
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

/// Ce que ferait une exécution, sans rien modifier.
public struct SimulationResult: Codable, Equatable, Sendable {
    public var status: RunStatus
    public var filesToTransfer: Int
    public var bytesToTransfer: Int64
    public var deletions: Int
    public var message: String?

    public init(status: RunStatus, filesToTransfer: Int, bytesToTransfer: Int64, deletions: Int, message: String?) {
        self.status = status
        self.filesToTransfer = filesToTransfer
        self.bytesToTransfer = bytesToTransfer
        self.deletions = deletions
        self.message = message
    }

    public init(_ result: RunResult) {
        self.init(
            status: result.status, filesToTransfer: result.summary.filesTransferred,
            bytesToTransfer: result.summary.bytesTransferred, deletions: result.summary.deletions,
            message: result.summary.message
        )
    }
}

public struct RunLogText: Codable, Equatable, Sendable {
    public var text: String
    /// Vrai si le début du journal n'est pas inclus.
    public var truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}
