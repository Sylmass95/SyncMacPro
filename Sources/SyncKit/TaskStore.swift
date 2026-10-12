import Foundation

/// Les tâches de l'utilisateur, dans un fichier JSON lisible.
public struct TaskStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Un fichier absent donne une liste vide ; un fichier illisible lève une erreur (il n'est jamais écrasé en silence).
    public func load() throws -> [SyncTask] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SyncTask].self, from: Data(contentsOf: url))
    }

    public func save(_ tasks: [SyncTask]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(tasks).write(to: url, options: .atomic)
    }

    /// Ajoute la tâche ou remplace celle qui a le même identifiant.
    public func upsert(_ task: SyncTask) throws {
        var tasks = try load()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        try save(tasks)
    }

    public func remove(id: UUID) throws {
        try save(try load().filter { $0.id != id })
    }
}
