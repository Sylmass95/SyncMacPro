import Foundation

/// Résultat d'une simulation rsync (`-n --stats --out-format=%l|%n`).
public struct RsyncPlan: Equatable, Sendable {
    /// Fichiers qui seraient copiés (nom relatif → taille).
    public var files: [String: Int64] = [:]
    /// Dossiers qui seraient créés ou touchés (noms terminés par « / »).
    public var directories: Set<String> = []
    /// Éléments qui seraient supprimés (modes qui suppriment).
    public var deletions: [String] = []
    /// Nombre de fichiers réguliers vus côté source (« Number of files: N (reg: R, … »).
    public var sourceRegularFiles: Int?
    /// Fichiers réguliers qui n'existent pas encore à la destination (« Number of created files: N (reg: R, … »).
    public var createdRegularFiles: Int?

    public var totalBytes: Int64 { files.values.reduce(0, +) }
    public init() {}
}

public enum RsyncPlanParser {
    private static let listing = try! NSRegularExpression(pattern: #"^(\d+)\|(.+)$"#)
    private static let regularFiles = try! NSRegularExpression(pattern: #"^Number of files: [\d,]+ \(reg: ([\d,]+)"#)
    private static let createdFiles = try! NSRegularExpression(pattern: #"^Number of created files: [\d,]+ \(reg: ([\d,]+)"#)

    public static func parse(_ text: String) -> RsyncPlan {
        var plan = RsyncPlan()
        for line in LineSplitter.lines(in: text) {
            if let name = captures(listing, in: line), name.count == 2 {
                let size = Int64(name[0]) ?? 0
                let path = name[1]
                if path == "./" { continue }
                if path.hasSuffix("/") { plan.directories.insert(path) } else { plan.files[path] = size }
            } else if line.hasPrefix("deleting ") {
                plan.deletions.append(String(line.dropFirst("deleting ".count)))
            } else if let reg = captures(regularFiles, in: line)?.first {
                plan.sourceRegularFiles = Int(reg.replacingOccurrences(of: ",", with: ""))
            } else if let created = captures(createdFiles, in: line)?.first {
                plan.createdRegularFiles = Int(created.replacingOccurrences(of: ",", with: ""))
            }
        }
        return plan
    }

    private static func captures(_ regex: NSRegularExpression, in line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
    }
}

/// Lecture des résultats de vérification (rsync `-rcn --out-format=%i|%n`, rclone `check --combined -`).
public enum VerifyParser {
    /// Fichiers qui diffèrent d'après rsync (ligne « >fc.T......|nom » ; « >f+++++++++|nom » pour un fichier absent).
    public static func rsyncDifferences(in text: String) -> [String] {
        LineSplitter.lines(in: text).compactMap { line in
            guard let bar = line.firstIndex(of: "|") else { return nil }
            let flags = line[..<bar]
            guard flags.count >= 2, flags[flags.index(after: flags.startIndex)] == "f" else { return nil }
            return String(line[line.index(after: bar)...])
        }
    }

    /// Fichiers qui diffèrent d'après rclone : « * » différent, « + » absent de la destination,
    /// « - » absent de la source, « ! » erreur. « = » signifie identique.
    public static func rcloneDifferences(in text: String) -> [String] {
        LineSplitter.lines(in: text).compactMap { line in
            guard let first = line.first, "*+-!".contains(first) else { return nil }
            return String(line.dropFirst(2))
        }
    }
}
