import Foundation

/// Un fichier traité par une exécution (1.8.2) : ce qui lui est arrivé, sa taille, son chemin.
public struct RunDetailRow: Codable, Equatable, Hashable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case added, updated, touched, deleted, archived

        /// Lettre du fichier de détails.
        var code: Character {
            switch self {
            case .added: return "A"
            case .updated: return "U"
            case .touched: return "T"
            case .deleted: return "D"
            case .archived: return "R"
            }
        }

        init?(code: Character) {
            guard let found = Action.allCases.first(where: { $0.code == code }) else { return nil }
            self = found
        }
    }

    public var action: Action
    public var size: Int64?
    public var path: String

    public init(action: Action, size: Int64?, path: String) {
        self.action = action
        self.size = size
        self.path = path
    }

    /// Une ligne du fichier de détails : « A<tab>taille<tab>chemin ».
    var line: String { "\(action.code)\t\(size.map(String.init) ?? "")\t\(path)\n" }

    init?(line: Substring) {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = parts[0].first, let action = Action(code: code) else { return nil }
        self.init(action: action, size: Int64(parts[1]), path: String(parts[2]))
    }
}

/// Détails d'une exécution : les premières lignes (plafonnées) et les totaux sur toutes.
public struct RunDetails: Codable, Equatable, Sendable {
    public struct Total: Codable, Equatable, Sendable {
        public var count: Int
        public var bytes: Int64
        public init(count: Int, bytes: Int64) {
            self.count = count
            self.bytes = bytes
        }
    }

    public var rows: [RunDetailRow]
    public var totals: [RunDetailRow.Action: Total]
    /// Plus de lignes que `maxRows` : les totaux comptent tout, la liste non.
    public var truncated: Bool

    public init(rows: [RunDetailRow], totals: [RunDetailRow.Action: Total], truncated: Bool) {
        self.rows = rows
        self.totals = totals
        self.truncated = truncated
    }

    public static func read(url: URL, maxRows: Int) throws -> RunDetails {
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [RunDetailRow] = [], totals: [RunDetailRow.Action: Total] = [:], count = 0
        for line in text.split(separator: "\n") {
            guard let row = RunDetailRow(line: line) else { continue }
            count += 1
            if rows.count < maxRows { rows.append(row) }
            var total = totals[row.action] ?? Total(count: 0, bytes: 0)
            total.count += 1
            total.bytes += row.size ?? 0
            totals[row.action] = total
        }
        return RunDetails(rows: rows, totals: totals, truncated: count > rows.count)
    }
}

/// Reconnaît dans une ligne du moteur un fichier copié, mis à jour, supprimé ou archivé.
public enum RunDetailParser {
    public static func parse(_ line: String) -> RunDetailRow? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("{") { return rclone(line) }
        if line.hasPrefix("deleting ") { return RunDetailRow(action: .deleted, size: nil, path: String(line.dropFirst("deleting ".count))) }
        return rsync(line)
    }

    /// rsync, format `%i|%l|%n`.
    private static func rsync(_ line: String) -> RunDetailRow? {
        let characters = Array(line)
        guard characters.count > 12, characters[11] == "|" else { return nil }
        let flags = String(characters[0..<11])
        let rest = String(characters[12...])
        var size: Int64?
        var path = rest
        if let bar = rest.firstIndex(of: "|"), bar > rest.startIndex, rest[..<bar].allSatisfy(\.isNumber) {
            size = Int64(rest[..<bar])
            path = String(rest[rest.index(after: bar)...])
        }
        if flags.hasPrefix("*deleting") { return RunDetailRow(action: .deleted, size: nil, path: path) }
        guard characters[1] == "f" || characters[1] == "L", "<>c.".contains(characters[0]) else { return nil }
        if characters[0] == "." { return RunDetailRow(action: .touched, size: size, path: path) }
        let isNew = flags.dropFirst(2).allSatisfy { $0 == "+" }
        return RunDetailRow(action: isNew ? .added : .updated, size: size, path: path)
    }

    /// rclone, journal JSON (`--use-json-log`) : « Copied (new) », « Deleted », « Moved (server-side) to: _ARCHIVE… ».
    private static func rclone(_ line: String) -> RunDetailRow? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = object["msg"] as? String, let path = object["object"] as? String else { return nil }
        let size = (object["size"] as? NSNumber)?.int64Value
        let action: RunDetailRow.Action
        if message.hasPrefix("Copied (new)") || message.hasPrefix("Copied (server-side copy)") || message == "Copied" {
            action = .added
        } else if message.hasPrefix("Copied (replaced existing)") || message.hasPrefix("Copied (Rcat") {
            action = .updated
        } else if message.hasPrefix("Deleted") {
            action = .deleted
        } else if message.hasPrefix("Moved") {
            action = .archived
        } else if message.hasPrefix("Updated modification time") {
            action = .touched
        } else {
            return nil
        }
        return RunDetailRow(action: action, size: size, path: path)
    }
}
