import Foundation
import SyncKit

public enum EditorStep: Int, CaseIterable, Sendable {
    case endpoints, mode, options, schedule, summary
}

extension TaskProblem {
    /// L'étape de l'éditeur où l'utilisateur corrige ce problème.
    public var step: EditorStep {
        switch self {
        case .missingSource, .missingDestination, .sameSourceAndDestination, .nestedFolders, .relativePath, .invalidItem: return .endpoints
        case .engineMismatch: return .mode
        case .invalidThreshold, .invalidArchiveFolder: return .options
        case .invalidSchedule: return .schedule
        case .emptyName: return .summary
        }
    }
}

public enum SideKind: String, CaseIterable, Sendable {
    case folder, cloud
}

/// Un côté de la tâche tel que l'utilisateur le saisit.
public struct SideDraft: Equatable, Sendable {
    public var kind: SideKind
    public var path: String
    public var remote: String

    public init(kind: SideKind = .folder, path: String = "", remote: String = "") {
        self.kind = kind
        self.path = path
        self.remote = remote
    }

    init(_ endpoint: Endpoint) {
        switch endpoint {
        case .local(let path): self.init(kind: .folder, path: path)
        case .network(_, let mountPath): self.init(kind: .folder, path: mountPath)
        case .cloud(let remote, let path): self.init(kind: .cloud, path: path, remote: remote)
        }
    }

    func endpoint(_ resolver: EndpointResolver) -> Endpoint {
        let path = self.path.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .folder:
            // « ~/Photos » saisi à la main : l'agent ne connaît pas « ~ ».
            return path.isEmpty ? .local(path: "") : resolver.endpoint(forPath: (path as NSString).expandingTildeInPath)
        case .cloud: return .cloud(remote: remote.trimmingCharacters(in: .whitespaces), path: path)
        }
    }
}

public enum ScheduleKind: String, CaseIterable, Sendable {
    case manual, daily, weekdays, everyMinutes, whenAvailable
}

/// Planification éditable : chaque genre garde ses réglages quand on passe de l'un à l'autre.
public struct ScheduleDraft: Equatable, Sendable {
    public var kind: ScheduleKind = .manual
    public var hour = 3
    public var minute = 0
    public var days: Set<Int> = [2, 3, 4, 5, 6]
    public var interval = 60

    public init() {}

    public init(_ schedule: Schedule) {
        self.init()
        switch schedule {
        case .manual: kind = .manual
        case .whenAvailable: kind = .whenAvailable
        case .everyMinutes(let minutes):
            kind = .everyMinutes
            interval = minutes
        case .daily(let hour, let minute):
            kind = .daily
            self.hour = hour
            self.minute = minute
        case .weekdays(let days, let hour, let minute):
            kind = .weekdays
            self.days = days
            self.hour = hour
            self.minute = minute
        }
    }

    public var schedule: Schedule {
        switch kind {
        case .manual: return .manual
        case .whenAvailable: return .whenAvailable
        case .everyMinutes: return .everyMinutes(interval)
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekdays: return .weekdays(days: days, hour: hour, minute: minute)
        }
    }
}

/// Section « Disque amovible » de l'éditeur : proposée quand la destination est sur un disque externe.
public struct RemovableDraft: Equatable, Sendable {
    /// Lier la tâche au disque (la sauvegarde part au branchement) : choix explicite de l'utilisateur.
    public var linked = false
    /// `nil` : volume sans identifiant (certains formats), il ne peut pas être lié.
    public var volumeUUID: String?
    public var volumeName: String
    public var relativePath: String
    public var everyConnection = true
    public var everyDays = 7
    public var resumeWindowDays = 3
    public var eject: RemovableDrive.Eject = .button

    public init?(volume: VolumeInfo, path: String) {
        guard volume.isRemovable else { return nil }
        volumeUUID = volume.uuid
        volumeName = volume.name
        relativePath = volume.relativePath(of: path)
    }

    public init(_ drive: RemovableDrive) {
        linked = true
        volumeUUID = drive.volumeUUID
        volumeName = drive.volumeName
        relativePath = drive.relativePath
        resumeWindowDays = drive.resumeWindowDays
        eject = drive.eject
        switch drive.trigger {
        case .everyConnection: everyConnection = true
        case .atMostEveryDays(let days):
            everyConnection = false
            everyDays = days
        }
    }

    /// Le volume de la destination a changé (autre dossier, autre disque) : identité reprise, réglages gardés.
    mutating func adopt(_ volume: VolumeInfo, path: String) {
        volumeUUID = volume.uuid
        volumeName = volume.name
        relativePath = volume.relativePath(of: path)
    }

    public var drive: RemovableDrive? {
        guard linked, let volumeUUID else { return nil }
        return RemovableDrive(
            volumeUUID: volumeUUID, volumeName: volumeName, relativePath: relativePath,
            trigger: everyConnection ? .everyConnection : .atMostEveryDays(max(1, everyDays)),
            resumeWindowDays: min(30, max(1, resumeWindowDays)), eject: eject
        )
    }
}

public enum TaskTemplate: String, CaseIterable, Identifiable, Sendable {
    case copyToNAS, syncTwoFolders, backupToDrive
    public var id: String { rawValue }
}

/// Brouillon d'une tâche dans l'éditeur : tout ce que l'utilisateur modifie, sans vue ni agent.
public struct TaskDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var source: SideDraft
    public var destination: SideDraft
    /// Conservés tels quels : ils seront modifiables avec la copie à deux panneaux.
    public var sourceItems: [String]
    public var mode: SyncMode
    public var options: TaskOptions
    public var conditions: TaskConditions
    public var scheduleDraft: ScheduleDraft
    public var notifications: NotificationPolicy
    public var isEnabled: Bool
    /// `nil` : destination ni sur un disque externe ni liée à un disque.
    public var removable: RemovableDraft?

    public init(id: UUID = UUID()) {
        self.id = id
        name = ""
        source = SideDraft()
        destination = SideDraft()
        sourceItems = []
        mode = .copy
        options = TaskOptions()
        conditions = TaskConditions()
        scheduleDraft = ScheduleDraft()
        notifications = .always
        isEnabled = true
    }

    public init(task: SyncTask) {
        id = task.id
        name = task.name
        source = SideDraft(task.source)
        destination = SideDraft(task.destination)
        sourceItems = task.sourceItems
        mode = task.mode
        options = task.options
        conditions = task.conditions
        scheduleDraft = ScheduleDraft(task.schedule)
        notifications = task.notifications
        isEnabled = task.isEnabled
        removable = task.removableDrive.map(RemovableDraft.init)
    }

    public static func duplicate(of task: SyncTask, suffix: String) -> TaskDraft {
        var draft = TaskDraft(task: task)
        draft.id = UUID()
        draft.name = "\(task.name) \(suffix)"
        return draft
    }

    public static func template(_ template: TaskTemplate) -> TaskDraft {
        var draft = TaskDraft()
        switch template {
        case .copyToNAS:
            draft.mode = .copy
            draft.scheduleDraft = ScheduleDraft(.daily(hour: 3, minute: 0))
            draft.conditions.requiresNetwork = true
            draft.notifications = .errorsOnly
        case .syncTwoFolders:
            draft.mode = .bidirectional
            draft.scheduleDraft = ScheduleDraft(.everyMinutes(60))
        case .backupToDrive:
            draft.mode = .copy
            draft.destination = SideDraft(kind: .cloud, path: "SyncMacPro", remote: "drive")
            draft.scheduleDraft = ScheduleDraft(.daily(hour: 2, minute: 0))
            draft.conditions.requiresNetwork = true
            draft.options.maxTransferGB = 750
            draft.notifications = .errorsOnly
        }
        return draft
    }

    public func task(resolver: EndpointResolver = .system) -> SyncTask {
        var task = SyncTask(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source.endpoint(resolver), destination: destination.endpoint(resolver), sourceItems: sourceItems,
            mode: mode, options: options, schedule: scheduleDraft.schedule, notifications: notifications,
            conditions: conditions, isEnabled: isEnabled
        )
        task.removableDrive = destination.kind == .folder ? removable?.drive : nil
        return task
    }

    /// Relit le volume de la destination : section proposée sur un disque externe, retirée sur un disque interne,
    /// un partage réseau ou un service en ligne ; disque débranché (chemin introuvable) : le lien est gardé.
    /// `adopting` faux (ouverture de l'éditeur, destination inchangée) : un lien existant n'est jamais changé, même si un
    /// autre disque du même nom répond au chemin enregistré.
    public mutating func refreshRemovable(adopting: Bool = true, lookup: (String) -> VolumeInfo? = VolumeLookup.info(forPath:)) {
        let path = (destination.path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard destination.kind == .folder, !path.isEmpty else { removable = nil; return }
        guard let volume = lookup(path) else { return }
        if !adopting, removable?.linked == true { return }
        guard volume.isRemovable else { removable = nil; return }
        if removable == nil { removable = RemovableDraft(volume: volume, path: path) } else { removable?.adopt(volume, path: path) }
    }

    /// Ce qui distingue deux exécutions : la tâche sans son nom (un renommage ne périme pas une simulation).
    public func simulationKey(resolver: EndpointResolver = .system) -> SyncTask {
        var key = task(resolver: resolver)
        key.name = ""
        return key
    }

    public func problems(resolver: EndpointResolver = .system) -> [TaskProblem] {
        TaskValidator.problems(in: task(resolver: resolver))
    }

    public func problems(for step: EditorStep, resolver: EndpointResolver = .system) -> [TaskProblem] {
        problems(resolver: resolver).filter { $0.step == step }
    }

    // MARK: champs texte

    /// Une exclusion par ligne ; lignes vides ignorées.
    public var excludesText: String {
        get { options.excludes.joined(separator: "\n") }
        set {
            options.excludes = newValue.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    public var bandwidthText: String {
        get { options.bandwidthLimitKBps.map(String.init) ?? "" }
        set { options.bandwidthLimitKBps = Self.positive(newValue) }
    }

    public var retentionText: String {
        get { options.retentionDays.map(String.init) ?? "" }
        set { options.retentionDays = Self.positive(newValue) }
    }

    public var maxTransferText: String {
        get { options.maxTransferGB.map(String.init) ?? "" }
        set { options.maxTransferGB = Self.positive(newValue) }
    }

    static func positive(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    // MARK: nom

    /// « Photos → drive:Sauvegardes ».
    public func suggestedName() -> String {
        func label(_ side: SideDraft) -> String {
            switch side.kind {
            case .folder:
                let last = URL(fileURLWithPath: side.path).lastPathComponent
                return last.isEmpty || last == "/" ? side.path : last
            case .cloud:
                return side.path.isEmpty ? side.remote : "\(side.remote):\(side.path)"
            }
        }
        return "\(label(source)) → \(label(destination))"
    }

    public mutating func fillNameIfNeeded() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = suggestedName() }
    }
}
