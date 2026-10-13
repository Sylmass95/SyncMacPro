import Foundation

/// Ce qui empêche d'enregistrer une tâche. L'agent refuse `saveTask` avec le message ; l'app traduit chaque cas.
public enum TaskProblem: String, Codable, CaseIterable, Equatable, Sendable {
    case emptyName
    case missingSource
    case missingDestination
    case sameSourceAndDestination
    /// La destination est dans la source, ou l'inverse : rsync recopierait la destination dans elle-même,
    /// un miroir effacerait la source.
    case nestedFolders
    case engineMismatch
    case invalidThreshold
    case invalidSchedule

    public var message: String {
        switch self {
        case .emptyName: return "Donnez un nom à la tâche."
        case .missingSource: return "Choisissez une source."
        case .missingDestination: return "Choisissez une destination."
        case .sameSourceAndDestination: return "La source et la destination sont le même dossier."
        case .nestedFolders: return "La destination ne peut pas être dans la source, ni la source dans la destination."
        case .engineMismatch: return "Le moteur choisi ne sait pas faire ce mode."
        case .invalidThreshold: return "Le seuil de suppression doit être compris entre 1 et 100 %."
        case .invalidSchedule: return "La planification est incomplète (heure, jours ou intervalle)."
        }
    }
}

public enum TaskValidator {
    /// Tous les problèmes, dans l'ordre des étapes de l'éditeur.
    public static func problems(in task: SyncTask) -> [TaskProblem] {
        var found: [TaskProblem] = []
        if task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.emptyName) }
        let sourceMissing = isEmpty(task.source)
        let destinationMissing = isEmpty(task.destination)
        if sourceMissing { found.append(.missingSource) }
        if destinationMissing { found.append(.missingDestination) }
        if !sourceMissing && !destinationMissing {
            let source = key(task.source), destination = key(task.destination)
            if source == destination {
                found.append(.sameSourceAndDestination)
            } else if task.source.isCloud == task.destination.isCloud,
                      source.hasPrefix(destination + "/") || destination.hasPrefix(source + "/") {
                found.append(.nestedFolders)
            }
        }
        if (try? EngineSelector.engine(for: task)) == nil { found.append(.engineMismatch) }
        if !(1...100).contains(task.options.deleteThresholdPercent) { found.append(.invalidThreshold) }
        if !isValid(task.schedule) { found.append(.invalidSchedule) }
        return found
    }

    static func isEmpty(_ endpoint: Endpoint) -> Bool {
        switch endpoint {
        case .local(let path): return path.trimmingCharacters(in: .whitespaces).isEmpty
        case .network(_, let mountPath): return mountPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .cloud(let remote, _): return remote.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Forme comparable : chemin normalisé sans « / » final, ou « remote:chemin ».
    static func key(_ endpoint: Endpoint) -> String {
        if let path = endpoint.filesystemPath {
            var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            while standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
            return standardized
        }
        var spec = endpoint.rcloneSpec
        while spec.hasSuffix("/") { spec.removeLast() }
        return spec
    }

    static func isValid(_ schedule: Schedule) -> Bool {
        func time(_ hour: Int, _ minute: Int) -> Bool { (0..<24).contains(hour) && (0..<60).contains(minute) }
        switch schedule {
        case .manual, .whenAvailable: return true
        case .everyMinutes(let minutes): return minutes >= 1
        case .daily(let hour, let minute): return time(hour, minute)
        case .weekdays(let days, let hour, let minute):
            return !days.isEmpty && days.allSatisfy { (1...7).contains($0) } && time(hour, minute)
        }
    }
}
