import Foundation

/// 1.8.10 : un nom de fichier que le partage monté par macOS liste mais n'ouvre pas.
///
/// Une lettre accentuée s'écrit « é » (un caractère) ou « e » + accent (la forme des Mac). Le client SMB de macOS envoie
/// toujours la première forme : un fichier enregistré sur le NAS sous la seconde est listé, puis « introuvable » à
/// l'ouverture (essai réel : 45 fichiers du NAS 03, lisibles dans File Station). Un nom présent sous les deux formes
/// apparaît deux fois à l'identique : rclone en ignore un (« Duplicate object »).
public enum SourceNameIssue: Equatable, Sendable {
    case unreadable(String)
    case duplicate(String)

    /// Journal JSON de rclone ; le chemin est relatif à la source.
    public static func parse(rcloneLine line: String) -> SourceNameIssue? {
        guard line.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = object["msg"] as? String, let path = object["object"] as? String, !path.isEmpty else { return nil }
        let lower = message.lowercased()
        if lower.hasPrefix("duplicate object found in source") { return .duplicate(path) }
        if object["level"] as? String == "error", lower.contains("failed to open source object"),
           lower.contains("no such file or directory") { return .unreadable(path) }
        return nil
    }

    /// Le chemin à demander au NAS : le nom du fichier tel que listé (c'est lui qui est mal enregistré), ses dossiers sous
    /// la forme habituelle (« é » en un caractère) : le partage monté les a ouverts, ils sont donc enregistrés ainsi.
    public static func directPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[..<slash]).precomposedStringWithCanonicalMapping + String(path[slash...])
    }

    /// rsync : `send_files failed to open "<chemin>": No such file or directory (2)`, rendu relatif à `sourceRoot`.
    public static func parse(rsyncLine line: String, sourceRoot: String) -> SourceNameIssue? {
        guard line.contains("send_files failed to open \""), line.contains("No such file or directory"),
              let start = line.range(of: "failed to open \"")?.upperBound,
              let end = line.range(of: "\": ", range: start..<line.endIndex)?.lowerBound else { return nil }
        let full = String(line[start..<end])
        let root = sourceRoot.hasSuffix("/") ? sourceRoot : sourceRoot + "/"
        guard full.hasPrefix(root) else { return nil }
        return .unreadable(String(full.dropFirst(root.count)))
    }
}

/// Le partage SMB d'une source réseau, pour la lire par une connexion directe (rclone, type `smb`).
public struct SMBShare: Equatable, Sendable {
    public var host: String
    public var user: String?
    public var share: String
    /// Dossier de la tâche dans le partage (vide : sa racine).
    public var subpath: String

    public init(host: String, user: String?, share: String, subpath: String) {
        self.host = host
        self.user = user
        self.share = share
        self.subpath = subpath
    }

    /// `smb://compte@hôte/partage` et le dossier monté (`/Volumes/partage/sous-dossier`).
    public static func of(_ endpoint: Endpoint) -> SMBShare? {
        guard case .network(let url, let mountPath) = endpoint, let components = URLComponents(string: url),
              components.scheme?.lowercased() == "smb", let host = components.host, !host.isEmpty else { return nil }
        let share = components.path.split(separator: "/").first.map(String.init) ?? ""
        guard !share.isEmpty else { return nil }
        var subpath = ""
        if let root = NetworkShare.volumesRoot(of: mountPath), mountPath.count > root.count {
            subpath = String(mountPath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return SMBShare(host: host, user: components.user.flatMap { $0.isEmpty ? nil : $0 }, share: share, subpath: subpath)
    }

    /// La connexion rclone de type `smb` vers le même hôte (et le même compte, s'il est connu) ; seuls le type, l'hôte et
    /// le compte sont lus.
    public static func remote(for share: SMBShare, config: String) -> String? {
        var sections: [(name: String, values: [String: String])] = []
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equal = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                guard ["type", "host", "user"].contains(key) else { continue }
                sections[sections.count - 1].values[key] = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return sections.first { section in
            section.values["type"] == "smb"
                && section.values["host"]?.lowercased() == share.host.lowercased()
                && (share.user == nil || section.values["user"] == nil || section.values["user"] == share.user)
        }?.name
    }

    /// `connexion:partage/sous-dossier`.
    public func spec(remote: String) -> String {
        subpath.isEmpty ? "\(remote):\(share)" : "\(remote):\(share)/\(subpath)"
    }
}

/// Textes du journal et du résumé (1.8.10).
public enum SourceNameText {
    static func files(_ count: Int) -> String { count > 1 ? "\(count) fichiers" : "1 fichier" }

    public static func recovered(_ count: Int) -> String {
        "\(files(count)) au nom mal enregistré sur le NAS (accents) \(count > 1 ? "ont été récupérés" : "a été récupéré") "
            + "par la connexion directe."
    }

    public static func unreadable(_ count: Int, hasDirectConnection: Bool, reason: String? = nil) -> String {
        let base = "\(files(count)) au nom mal enregistré sur le NAS (accents) : le partage monté sur le Mac ne sait pas "
            + "\(count > 1 ? "les " : "l'")ouvrir (liste dans les détails)."
        guard hasDirectConnection else {
            return base + " Ajoutez une connexion « NAS (SMB direct) » vers ce NAS dans Connexions : SyncMacPro les "
                + "récupérera par elle. Ou renommez-les sur le NAS (File Station) en retapant les accents."
        }
        return base + " La connexion directe n'a pas pu \(count > 1 ? "les" : "le") lire" + (reason.map { " : \($0)" } ?? ".")
    }

    public static func duplicates(_ count: Int) -> String {
        "\(count > 1 ? "\(count) noms" : "1 nom") en double sur le NAS (même nom sous deux formes d'accents) : une seule "
            + "version copiée (liste dans les détails)."
    }

    static func unreadableLine(_ path: String) -> String {
        "Nom mal enregistré sur le NAS (accents), illisible par le partage monté : \(path)"
    }

    static func duplicateLine(_ path: String) -> String {
        "Doublon sur le NAS (même nom sous deux formes d'accents, une seule version copiée) : \(path)"
    }
}

/// Noms illisibles et doublons relevés pendant une copie.
final class SourceNameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var unreadableSet: [String] = []
    private var duplicateSet: [String] = []

    func note(_ issue: SourceNameIssue?) {
        guard let issue else { return }
        lock.lock(); defer { lock.unlock() }
        switch issue {
        case .unreadable(let path): if !unreadableSet.contains(path) { unreadableSet.append(path) }
        case .duplicate(let path): if !duplicateSet.contains(path) { duplicateSet.append(path) }
        }
    }

    var unreadable: [String] { lock.lock(); defer { lock.unlock() }; return unreadableSet }
    var duplicates: [String] { lock.lock(); defer { lock.unlock() }; return duplicateSet }
}
