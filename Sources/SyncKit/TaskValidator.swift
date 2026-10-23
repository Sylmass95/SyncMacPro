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
    /// Un chemin doit être complet (commencer par « / »).
    case relativePath
    /// Le dossier d'archive doit être un simple nom, dans la destination.
    case invalidArchiveFolder
    /// Un élément choisi doit être un nom (ou un chemin) dans la source : ni vide, ni « . », ni « .. », ni absolu.
    case invalidItem
    /// Accès SSH (1.8.1) : utilisateur, serveur et chemin complet, pour une tâche avec un seul partage réseau.
    case invalidSSH

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
        case .relativePath: return "Les chemins doivent être complets (commencer par /)."
        case .invalidArchiveFolder: return "Le dossier d'archive doit être un simple nom, sans « / » ni « .. »."
        case .invalidItem: return "Les éléments choisis doivent être des noms dans la source (ni vide, ni « . », ni « .. »)."
        case .invalidSSH: return "L'accès SSH demande un utilisateur, un serveur et un chemin complet, et un seul côté sur un partage réseau."
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
            if isRelative(task.source) || isRelative(task.destination) {
                found.append(.relativePath)
            } else {
                let source = location(task.source), destination = location(task.destination)
                if !task.sourceItems.allSatisfy(isValidItem) {
                    found.append(.invalidItem)
                } else if source.namespace == destination.namespace {
                    if let problem = task.sourceItems.isEmpty
                        ? overlap(source.parts, destination.parts)
                        : overlap(items: task.sourceItems, in: source, destination.parts) {
                        found.append(problem)
                    }
                }
            }
        }
        if (try? EngineSelector.engine(for: task)) == nil { found.append(.engineMismatch) }
        if !(1...100).contains(task.options.deleteThresholdPercent) { found.append(.invalidThreshold) }
        if (task.mode == .mirror || task.mode == .versioned) && !isValidArchiveFolder(task.options.archiveFolder) {
            found.append(.invalidArchiveFolder)
        }
        if !isValid(task.schedule) { found.append(.invalidSchedule) }
        // SSH ne sert qu'à rsync : un mode fait par rclone l'ignorerait sans le dire.
        if task.sshAccess != nil, RsyncCommandBuilder.ssh(task) == nil || (try? EngineSelector.engine(for: task)) != .rsync {
            found.append(.invalidSSH)
        }
        return found
    }

    /// Tout un dossier : il ne doit ni être la destination, ni la contenir, ni être dans elle.
    static func overlap(_ source: [String], _ destination: [String]) -> TaskProblem? {
        if source == destination { return .sameSourceAndDestination }
        if source.starts(with: destination) || destination.starts(with: source) { return .nestedFolders }
        return nil
    }

    /// Des éléments choisis : chacun est jugé avec l'endroit où il arrive (`destination/nom`). Copier /a/b/x.txt
    /// dans /a ou /a/c est légitime ; la destination ne doit pas être dans un élément, ni l'arrivée contenir l'élément.
    static func overlap(items: [String], in source: Location, _ destination: [String]) -> TaskProblem? {
        if source.parts == destination { return .sameSourceAndDestination }
        for item in items {
            var parts = item.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            if source.namespace.isEmpty { parts = parts.map { $0.lowercased() } }
            guard let name = parts.last else { continue }
            let path = source.parts + parts
            let arrival = destination + [name]
            if destination.starts(with: path) || path.starts(with: arrival) { return .nestedFolders }
        }
        return nil
    }

    /// « photos/2024 » ou « .cache » ; jamais vide, absolu, ni avec un composant « . » ou « .. » (qui sortirait de la source
    /// ou désignerait la source elle-même : un miroir effacerait alors la destination entière).
    static func isValidItem(_ item: String) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return false }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.isEmpty && !parts.contains { $0 == "." || $0 == ".." }
    }

    static func isEmpty(_ endpoint: Endpoint) -> Bool {
        switch endpoint {
        case .local(let path): return path.trimmingCharacters(in: .whitespaces).isEmpty
        case .network(_, let mountPath): return mountPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .cloud(let remote, _): return remote.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func isRelative(_ endpoint: Endpoint) -> Bool {
        guard let path = endpoint.filesystemPath else { return false }
        return !path.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    /// Où se trouve un côté : l'espace (disques du Mac, ou un service en ligne) et le chemin découpé.
    struct Location: Equatable {
        let namespace: String
        let parts: [String]
    }

    /// Chemin normalisé, liens symboliques résolus (« /tmp » est « /private/tmp »), sans tenir compte de la casse :
    /// APFS ne la distingue pas par défaut (au pire, un refus de trop sur un volume sensible à la casse).
    /// La racine « / » donne une liste vide : elle contient tout.
    static func location(_ endpoint: Endpoint) -> Location {
        if let path = endpoint.filesystemPath {
            let resolved = canonicalPath(path.trimmingCharacters(in: .whitespaces))
            return Location(namespace: "", parts: resolved.lowercased().split(separator: "/").map(String.init))
        }
        if case .cloud(let remote, let path) = endpoint {
            let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            return Location(namespace: "cloud:" + remote.trimmingCharacters(in: .whitespaces), parts: parts)
        }
        return Location(namespace: "", parts: [])
    }

    /// `realpath` du plus profond dossier existant, puis le reste du chemin : un dossier qui n'existe pas encore
    /// (destination à créer) est comparé sous la même forme que les autres (« /tmp/a » devient « /private/tmp/a »).
    static func canonicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path
        var rest: [String] = []
        while existing != "/" && !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base: String = buffer.withUnsafeMutableBufferPointer { pointer in
            guard let start = pointer.baseAddress, realpath(existing, start) != nil else { return existing }
            return String(cString: start)
        }
        return rest.isEmpty ? base : (base as NSString).appendingPathComponent(rest.joined(separator: "/"))
    }

    /// Un simple nom : sinon l'archive sortirait de la destination, ou ne protégerait plus rien (« »).
    static func isValidArchiveFolder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
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
