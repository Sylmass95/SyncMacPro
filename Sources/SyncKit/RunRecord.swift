import Foundation

public enum RunStatus: String, Codable, CaseIterable, Sendable {
    case running
    case succeeded
    case failed
    /// Refusée par un garde-fou (trop de suppressions).
    case blocked
    /// Quota de transfert atteint (par exemple 750 Go par jour sur Google Drive) : reprise plus tard.
    case quotaReached
    /// L'app ou le Mac s'est arrêté pendant l'exécution.
    case interrupted
    case stopped

    public var isFinished: Bool { self != .running }
}

public struct RunSummary: Codable, Equatable, Sendable {
    public var filesTransferred: Int
    public var bytesTransferred: Int64
    public var deletions: Int
    public var errors: Int
    public var durationSeconds: Double
    /// Explication lisible (motif d'un blocage ou d'un échec, « Simulation », …).
    public var message: String?
    /// Dossiers traités et vitesse moyenne (octets/s) : facultatifs, absents des exécutions d'avant 1.3.0.
    public var directories: Int?
    public var averageSpeed: Double?

    public init(
        filesTransferred: Int = 0, bytesTransferred: Int64 = 0, deletions: Int = 0,
        errors: Int = 0, durationSeconds: Double = 0, message: String? = nil,
        directories: Int? = nil, averageSpeed: Double? = nil
    ) {
        self.directories = directories
        self.averageSpeed = averageSpeed
        self.filesTransferred = filesTransferred
        self.bytesTransferred = bytesTransferred
        self.deletions = deletions
        self.errors = errors
        self.durationSeconds = durationSeconds
        self.message = message
    }
}

public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var taskName: String
    public var engine: EngineKind
    public var mode: SyncMode
    public var dryRun: Bool
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var summary: RunSummary?
    public var logPath: String?

    public init(
        id: UUID = UUID(), taskID: UUID, taskName: String, engine: EngineKind, mode: SyncMode,
        dryRun: Bool = false, startedAt: Date, finishedAt: Date? = nil, status: RunStatus = .running,
        summary: RunSummary? = nil, logPath: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.engine = engine
        self.mode = mode
        self.dryRun = dryRun
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.summary = summary
        self.logPath = logPath
    }
}
