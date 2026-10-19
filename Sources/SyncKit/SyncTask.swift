import Foundation

public enum NotificationPolicy: String, Codable, CaseIterable, Sendable {
    case always
    case errorsOnly
    case never
}

public struct TaskOptions: Codable, Equatable, Hashable, Sendable {
    /// `.tmp.driveupload/` et `.tmp.drivedownload/` : fichiers en cours d'envoi ou de réception de Google Drive pour
    /// ordinateur, dans un dossier qu'il synchronise ; temporaires, gros et changeants (1.6.8).
    public static let defaultExcludes = [".DS_Store", "Thumbs.db", "._*", "@eaDir/", "#recycle/", ".tmp.driveupload/", ".tmp.drivedownload/"]

    public var excludes: [String]
    /// Limite de débit en Ko/s ; `nil` = illimité.
    public var bandwidthLimitKBps: Int?
    public var verifyAfterCopy: Bool
    /// Au-delà de ce pourcentage de suppressions, une exécution est bloquée.
    public var deleteThresholdPercent: Int
    /// Nom du dossier d'archive créé à la racine de la destination.
    public var archiveFolder: String
    /// Durée de conservation des anciennes versions (mode `versioned`).
    public var retentionDays: Int?
    /// Quota de transfert par exécution, en Go (par exemple 750 pour Google Drive).
    public var maxTransferGB: Int?
    public var forcedEngine: EngineKind?
    /// Options avancées passées telles quelles au moteur (utilisateurs experts, diagnostics).
    public var extraArguments: [String]

    public init(
        excludes: [String] = TaskOptions.defaultExcludes,
        bandwidthLimitKBps: Int? = nil,
        verifyAfterCopy: Bool = false,
        deleteThresholdPercent: Int = 25,
        archiveFolder: String = "_ARCHIVE",
        retentionDays: Int? = nil,
        maxTransferGB: Int? = nil,
        forcedEngine: EngineKind? = nil,
        extraArguments: [String] = []
    ) {
        self.excludes = excludes
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.verifyAfterCopy = verifyAfterCopy
        self.deleteThresholdPercent = deleteThresholdPercent
        self.archiveFolder = archiveFolder
        self.retentionDays = retentionDays
        self.maxTransferGB = maxTransferGB
        self.forcedEngine = forcedEngine
        self.extraArguments = extraArguments
    }
}

public struct SyncTask: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var source: Endpoint
    public var destination: Endpoint
    /// Si non vide : seuls ces éléments (noms relatifs à la source) sont copiés, un dossier étant copié en tant que dossier.
    public var sourceItems: [String]
    public var mode: SyncMode
    public var options: TaskOptions
    public var schedule: Schedule
    public var notifications: NotificationPolicy
    public var conditions: TaskConditions
    public var isEnabled: Bool
    /// Destination sur un disque amovible (1.4.0) ; `nil` pour une tâche ordinaire.
    public var removableDrive: RemovableDrive?

    public init(
        id: UUID = UUID(),
        name: String,
        source: Endpoint,
        destination: Endpoint,
        sourceItems: [String] = [],
        mode: SyncMode = .copy,
        options: TaskOptions = TaskOptions(),
        schedule: Schedule = .manual,
        notifications: NotificationPolicy = .always,
        conditions: TaskConditions = TaskConditions(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.destination = destination
        self.sourceItems = sourceItems
        self.mode = mode
        self.options = options
        self.schedule = schedule
        self.notifications = notifications
        self.conditions = conditions
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(Endpoint.self, forKey: .source)
        destination = try container.decode(Endpoint.self, forKey: .destination)
        sourceItems = try container.decode([String].self, forKey: .sourceItems)
        mode = try container.decode(SyncMode.self, forKey: .mode)
        options = try container.decode(TaskOptions.self, forKey: .options)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        notifications = try container.decode(NotificationPolicy.self, forKey: .notifications)
        // Les fichiers écrits avant le sous-projet 2 n'ont pas cette clé.
        conditions = try container.decodeIfPresent(TaskConditions.self, forKey: .conditions) ?? TaskConditions()
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        removableDrive = try container.decodeIfPresent(RemovableDrive.self, forKey: .removableDrive)
    }
}
