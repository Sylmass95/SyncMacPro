import Foundation

/// Un fichier traité par une exécution (1.8.2) : ce qui lui est arrivé, sa taille, son chemin.
public struct RunDetailRow: Codable, Equatable, Hashable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case added, updated, touched, deleted, archived
        /// 1.8.10 : nom mal enregistré sur le NAS, lu par la connexion directe ; illisible ; présent en double.
        case recovered, unreadable, duplicate

        /// Lettre du fichier de détails.
        var code: Character {
            switch self {
            case .added: return "A"
            case .updated: return "U"
            case .touched: return "T"
            case .deleted: return "D"
            case .archived: return "R"
            case .recovered: return "K"
            case .unreadable: return "I"
            case .duplicate: return "W"
            }
        }

        init?(code: Character) {
            guard let found = Action.allCases.first(where: { $0.code == code }) else { return nil }
            self = found
        }
    }

    /// D'où vient le fichier (1.8.3) : la source ou la destination de la tâche (rsync), ou le côté en ligne / sur le
    /// disque (rclone, d'après l'objet qu'il nomme). `nil` : inconnu (détails de la 1.8.2).
    public enum Origin: String, Codable, Sendable {
        case source, destination, cloud, local

        var code: Character {
            switch self {
            case .source: return "S"
            case .destination: return "D"
            case .cloud: return "C"
            case .local: return "L"
            }
        }

        init?(code: Substring) {
            switch code {
            case "S": self = .source
            case "D": self = .destination
            case "C": self = .cloud
            case "L": self = .local
            default: return nil
            }
        }
    }

    public var action: Action
    public var size: Int64?
    public var path: String
    public var origin: Origin?

    public init(action: Action, size: Int64?, path: String, origin: Origin? = nil) {
        self.action = action
        self.size = size
        self.path = path
        self.origin = origin
    }

    /// Une ligne du fichier de détails : « A<tab>taille<tab>origine<tab>chemin » (1.8.2 : sans l'origine).
    var line: String { "\(action.code)\t\(size.map(String.init) ?? "")\t\(origin.map { String($0.code) } ?? "-")\t\(path)\n" }

    init?(line: Substring) {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, let code = parts[0].first, let action = Action(code: code) else { return nil }
        if parts.count == 4, parts[2] == "-" || Origin(code: parts[2]) != nil {
            self.init(action: action, size: Int64(parts[1]), path: String(parts[3]), origin: Origin(code: parts[2]))
        } else {
            self.init(action: action, size: Int64(parts[1]), path: parts.dropFirst(2).joined(separator: "\t"))
        }
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
        let rows = consolidated(text.split(separator: "\n").compactMap { RunDetailRow(line: $0) })
        var totals: [RunDetailRow.Action: Total] = [:]
        for row in rows {
            var total = totals[row.action] ?? Total(count: 0, bytes: 0)
            total.count += 1
            total.bytes += row.size ?? 0
            totals[row.action] = total
        }
        return RunDetails(rows: Array(rows.prefix(maxRows)), totals: totals, truncated: rows.count > maxRows)
    }

    /// Une ligne par fichier et par action (1.8.3) : rclone écrit deux fois chaque déplacement vers _ARCHIVE, et la
    /// taille d'un fichier archivé arrive après coup (liste de l'archive). Un fichier archivé puis recopié a été mis à
    /// jour ; un fichier supprimé qu'on retrouve dans l'archive y a été mis de côté.
    static func consolidated(_ raw: [RunDetailRow]) -> [RunDetailRow] {
        struct Key: Hashable { let action: RunDetailRow.Action; let path: String }
        var order: [Key] = [], merged: [Key: RunDetailRow] = [:]
        for row in raw {
            let key = Key(action: row.action, path: row.path)
            if var existing = merged[key] {
                existing.size = existing.size ?? row.size
                existing.origin = existing.origin ?? row.origin
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = row
            }
        }
        let archived = Set(order.filter { $0.action == .archived }.map(\.path))
        // 1.8.10 : un fichier rattrapé par la connexion directe n'a qu'une ligne, avec la taille de sa copie.
        let recovered = Set(order.filter { $0.action == .recovered }.map(\.path))
        var result: [RunDetailRow] = [], seen = Set<Key>()
        for key in order {
            guard var row = merged[key] else { continue }
            if recovered.contains(row.path), [.added, .updated, .unreadable].contains(row.action) { continue }
            if row.action == .recovered, row.size == nil {
                row.size = merged[Key(action: .added, path: row.path)]?.size ?? merged[Key(action: .updated, path: row.path)]?.size
            }
            if row.action == .deleted, archived.contains(row.path) { continue }
            if row.action == .added, archived.contains(row.path) {
                row.action = .updated
                if let other = merged[Key(action: .updated, path: row.path)] { row.size = row.size ?? other.size }
            }
            guard seen.insert(Key(action: row.action, path: row.path)).inserted else { continue }
            result.append(row)
        }
        return result
    }
}

/// Reconnaît dans une ligne du moteur un fichier copié, mis à jour, supprimé ou archivé.
public enum RunDetailParser {
    public static func parse(_ line: String) -> RunDetailRow? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("{") { return rclone(line) }
        if line.hasPrefix("deleting ") {
            return RunDetailRow(action: .deleted, size: nil, path: String(line.dropFirst("deleting ".count)), origin: .destination)
        }
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
        if flags.hasPrefix("*deleting") { return RunDetailRow(action: .deleted, size: nil, path: path, origin: .destination) }
        guard characters[1] == "f" || characters[1] == "L", "<>c.".contains(characters[0]) else { return nil }
        if characters[0] == "." { return RunDetailRow(action: .touched, size: size, path: path, origin: .destination) }
        let isNew = flags.dropFirst(2).allSatisfy { $0 == "+" }
        return RunDetailRow(action: isNew ? .added : .updated, size: size, path: path, origin: .source)
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
        // « *local.Object » : un fichier sur le disque (Mac, NAS, disque), « *smb.Object » : le NAS par connexion directe
        // (1.8.10) ; tout autre type : le service en ligne.
        let origin: RunDetailRow.Origin? = (object["objectType"] as? String).map { $0.contains("local") || $0.contains("smb") ? .local : .cloud }
        return RunDetailRow(action: action, size: size, path: path, origin: origin)
    }
}
