import Foundation

public enum RsyncEvent: Equatable, Sendable {
    /// Un fichier commence à être copié. `isNew` vaut `nil` si rsync ne l'indique pas (format sans `%i`).
    case fileStarted(name: String, isNew: Bool?)
    /// rsync entre dans un dossier (créé ou mis à jour).
    case directory(name: String)
    /// Progression du fichier en cours ; `fileFinished` vrai sur la dernière ligne du fichier.
    case progress(bytes: Int64, percent: Int, bytesPerSecond: Double, fileFinished: Bool)
    case deleting(name: String)
    /// Messages d'information (« sending incremental file list », « sent … »).
    case message(String)
    case error(String)
}

public enum RsyncOutputParser {
    private static let progressPattern = try! NSRegularExpression(
        pattern: #"^([\d,]+)\s+(\d+)%\s+([\d.]+)([kKMGT]?)B/s\s+\d+:\d+:\d+(\s+\(xfr#.*\))?$"#
    )
    private static let units: [String: Double] = [
        "": 1, "k": 1024, "K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776,
    ]
    private static let messagePrefixes = [
        "sending incremental", "sent ", "total size", "building file", "created directory", "file has vanished",
    ]

    /// Interprète une ligne (déjà découpée par `LineSplitter`). Retourne `nil` pour les lignes à ignorer.
    public static func parse(line: String) -> RsyncEvent? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line == "./" || line == "." { return nil }

        if let progress = parseProgress(line) { return progress }
        if isError(line) { return .error(line) }
        switch parseItemized(line) {
        case .event(let event): return event
        case .ignored: return nil
        case .notItemized: break
        }
        if line.hasPrefix("deleting ") { return .deleting(name: String(line.dropFirst("deleting ".count))) }
        if messagePrefixes.contains(where: { line.hasPrefix($0) }) { return .message(line) }
        if line.hasSuffix("/") { return .directory(name: line) }
        return .fileStarted(name: line, isNew: nil)
    }

    private enum Itemized {
        /// La ligne n'est pas au format `%i|%n`.
        case notItemized
        /// Au format `%i|%n`, mais sans rien à suivre (lien symbolique, simple changement de date…).
        case ignored
        case event(RsyncEvent)
    }

    /// Format `%i|%l|%n` (1.8.2 : la taille en plus) ou `%i|%n` : 11 caractères d'état, « | », puis le nom.
    private static func parseItemized(_ line: String) -> Itemized {
        let characters = Array(line)
        guard characters.count > 12, characters[11] == "|" else { return .notItemized }
        let flags = String(characters[0..<11])
        let name = withoutSize(String(characters[12...]))
        if flags.hasPrefix("*deleting") { return .event(.deleting(name: name)) }
        guard let first = flags.first, "<>c.h".contains(first) else { return .notItemized }
        let type = characters[1]
        if type == "d" { return name == "./" ? .ignored : .event(.directory(name: name)) }
        // Seuls « > » (reçu) et « < » (envoyé) transfèrent des données d'un fichier.
        guard type == "f", first == ">" || first == "<" else { return .ignored }
        return .event(.fileStarted(name: name, isNew: flags.dropFirst(2).allSatisfy { $0 == "+" }))
    }

    /// « 1234|chemin » → « chemin » (format `%i|%l|%n`).
    static func withoutSize(_ rest: String) -> String {
        guard let bar = rest.firstIndex(of: "|"), bar > rest.startIndex, rest[..<bar].allSatisfy(\.isNumber) else { return rest }
        return String(rest[rest.index(after: bar)...])
    }

    private static func parseProgress(_ line: String) -> RsyncEvent? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = progressPattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        let bytes = Int64(group(1).replacingOccurrences(of: ",", with: "")) ?? 0
        let percent = Int(group(2)) ?? 0
        let speed = (Double(group(3)) ?? 0) * (units[group(4)] ?? 1)
        return .progress(bytes: bytes, percent: percent, bytesPerSecond: speed, fileFinished: !group(5).isEmpty)
    }

    private static func isError(_ line: String) -> Bool {
        line.hasPrefix("rsync:") || line.contains("rsync error") || line.contains("): error:")
    }
}
