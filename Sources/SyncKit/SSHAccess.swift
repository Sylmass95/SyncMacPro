import Foundation

/// Accès SSH à un partage réseau (1.8.1) : rsync tourne aussi sur le NAS, qui parcourt son propre disque au lieu de
/// répondre à une question réseau par fichier (essai réel QNAP, 155 000 fichiers : 26 s au lieu de plus de 18 min).
/// Le partage reste monté : il sert aux petites vérifications (fichiers vides, progression).
public struct SSHAccess: Codable, Equatable, Hashable, Sendable {
    public var user: String
    public var host: String
    /// Racine du partage sur le NAS (par exemple `/share/Documents`). Le dossier exact se déduit à chaque exécution du
    /// dossier de la tâche sur le partage : changer de sous-dossier ne laisse jamais rsync dans l'ancien dossier.
    public var path: String
    /// Le partage auquel cet accès s'applique : un autre partage passe par son montage.
    public var shareURL: String

    public init(user: String, host: String, path: String, shareURL: String) {
        self.user = user
        self.host = host
        self.path = path
        self.shareURL = shareURL
    }

    public var target: String { "\(user)@\(host)" }

    /// Jamais de mot de passe demandé (la clé SSH de l'utilisateur sert) ; une connexion coupée est vue en deux minutes.
    static let shellCommand = "ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"

    /// Arguments rsync : passage par SSH, noms gardés tels quels (espaces), et conversion des noms accentués
    /// (le Mac les écrit décomposés, le NAS composés : sans conversion, rsync les croirait absents).
    var rsyncArguments: [String] { ["-e", Self.shellCommand, "--protect-args", "--iconv=UTF-8-MAC,UTF-8"] }

    /// Utilisateur et serveur sans espace ni « @ », « : » ou « - » en tête (ssh le lirait comme une option) ; racine
    /// complète.
    public var isComplete: Bool {
        func valid(_ word: String) -> Bool {
            !word.isEmpty && !word.hasPrefix("-") && !word.contains { $0.isWhitespace || $0 == "@" || $0 == ":" }
        }
        return valid(user) && valid(host) && path.hasPrefix("/") && path == path.trimmingCharacters(in: .whitespaces)
    }

    /// Le même accès, espaces de saisie retirés.
    public var trimmed: SSHAccess {
        SSHAccess(user: user.trimmingCharacters(in: .whitespaces), host: host.trimmingCharacters(in: .whitespaces),
                  path: path.trimmingCharacters(in: .whitespaces), shareURL: shareURL)
    }

    /// Dossier sur le NAS pour ce côté de la tâche ; `nil` si ce n'est pas le partage de cet accès.
    public func remotePath(for endpoint: Endpoint) -> String? {
        guard case .network(let url, let mountPath) = endpoint, url == shareURL else { return nil }
        let inside = Self.inside(mountPath)
        return inside.isEmpty ? path : Endpoint.join(path, inside)
    }

    /// Chemin dans le partage : ce qui suit « /Volumes/<point de montage> ».
    static func inside(_ mountPath: String) -> String {
        let parts = mountPath.split(separator: "/").map(String.init)
        return parts.count > 2 && parts[0] == "Volumes" ? parts.dropFirst(2).joined(separator: "/") : ""
    }

    /// Proposition pour un partage monté : même utilisateur et même serveur que l'adresse du partage, racine
    /// `/share/<partage>` (la disposition d'un QNAP ; modifiable).
    public static func suggested(for endpoint: Endpoint) -> SSHAccess? {
        guard case .network(let url, _) = endpoint, let components = URLComponents(string: url),
              var host = components.host, !host.isEmpty else { return nil }
        host = host.replacingOccurrences(of: "._smb._tcp.local", with: ".local")
        let user = (components.percentEncodedUser?.removingPercentEncoding).flatMap { $0.isEmpty ? nil : $0 } ?? "admin"
        let share = (components.path.split(separator: "/").first.map(String.init) ?? "").removingPercentEncoding ?? ""
        return SSHAccess(user: user, host: host, path: share.isEmpty ? "/share" : "/share/\(share)", shareURL: url)
    }

    /// rsync rend 255 quand ssh n'a pas pu se connecter (clé refusée, serveur injoignable).
    public static func failureMessage(code: Int32, access: SSHAccess) -> String? {
        guard code == 255 else { return nil }
        return "Connexion SSH impossible à \(access.target) : serveur injoignable ou clé SSH refusée (essayez « ssh \(access.target) » dans le Terminal)."
    }

    /// rsync ne convertit pas les motifs d'exclusion avec --iconv : chaque motif est donné sous ses deux formes
    /// (composée et décomposée), pour valoir des deux côtés.
    static func bothForms(_ patterns: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for pattern in patterns {
            for form in [pattern, pattern.precomposedStringWithCanonicalMapping, pattern.decomposedStringWithCanonicalMapping]
            where seen.insert(form).inserted { result.append(form) }
        }
        return result
    }
}
