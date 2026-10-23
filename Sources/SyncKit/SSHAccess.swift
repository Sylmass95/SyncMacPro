import Foundation

/// Accès SSH à un partage réseau (1.8.1) : rsync tourne aussi sur le NAS, qui parcourt son propre disque au lieu de
/// répondre à une question réseau par fichier (essai réel QNAP, 155 000 fichiers : 55 s au lieu de plus de 18 min).
/// Le partage reste monté : il sert aux petites vérifications (fichiers vides, progression).
public struct SSHAccess: Codable, Equatable, Hashable, Sendable {
    public var user: String
    public var host: String
    /// Dossier sur le NAS qui correspond au dossier de la tâche sur le partage (par exemple `/share/Documents/PERSO-FILES`).
    public var path: String

    public init(user: String, host: String, path: String) {
        self.user = user
        self.host = host
        self.path = path
    }

    public var target: String { "\(user)@\(host)" }

    /// Jamais de mot de passe demandé (la clé SSH de l'utilisateur sert) ; une connexion coupée est vue en deux minutes.
    static let shellCommand = "ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"

    /// Arguments rsync : passage par SSH, noms gardés tels quels (espaces), et conversion des noms accentués
    /// (le Mac les écrit décomposés, le NAS composés : sans conversion, rsync les croirait absents).
    var rsyncArguments: [String] { ["-e", Self.shellCommand, "--protect-args", "--iconv=UTF-8-MAC,UTF-8"] }

    var isComplete: Bool {
        ![user, host, path].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } && path.hasPrefix("/")
    }

    /// Proposition pour un partage monté : même utilisateur et même serveur que l'adresse du partage, dossier
    /// `/share/<partage>/…` (la disposition d'un QNAP ; modifiable).
    public static func suggested(for endpoint: Endpoint) -> SSHAccess? {
        guard case .network(let url, let mountPath) = endpoint, let components = URLComponents(string: url),
              var host = components.host, !host.isEmpty else { return nil }
        host = host.replacingOccurrences(of: "._smb._tcp.local", with: ".local")
        let user = (components.percentEncodedUser?.removingPercentEncoding).flatMap { $0.isEmpty ? nil : $0 } ?? "admin"
        let share = components.path.split(separator: "/").first.map(String.init) ?? ""
        // Chemin dans le partage : ce qui suit « /Volumes/<point de montage> ».
        let parts = mountPath.split(separator: "/").map(String.init)
        let inside = parts.count > 2 && parts[0] == "Volumes" ? parts.dropFirst(2).joined(separator: "/") : ""
        let path = inside.isEmpty ? "/share/\(share)" : "/share/\(share)/\(inside)"
        return SSHAccess(user: user, host: host, path: path)
    }

    /// rsync rend 255 quand ssh n'a pas pu se connecter (clé refusée, serveur injoignable).
    public static func failureMessage(code: Int32, access: SSHAccess) -> String? {
        guard code == 255 else { return nil }
        return "Connexion SSH impossible à \(access.target) : serveur injoignable ou clé SSH refusée (essayez « ssh \(access.target) » dans le Terminal)."
    }
}
