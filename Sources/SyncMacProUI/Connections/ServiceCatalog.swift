import Foundation

/// Les services proposés par l'assistant.
public enum CloudService: String, CaseIterable, Identifiable, Sendable {
    /// 1.8.10 : `smb` : le NAS lu directement, pour les noms que le partage monté sur le Mac ne sait pas ouvrir.
    case drive, dropbox, onedrive, s3, smb
    public var id: String { rawValue }

    public var rcloneType: String { rawValue }

    /// Services proposés par l'assistant. 1.8.12 : plus le NAS, dont la connexion directe est déduite du partage et du
    /// trousseau (une connexion créée avant reste reconnue).
    public static var wizardChoices: [CloudService] { allCases.filter { $0 != .smb } }

    public var symbol: String {
        switch self {
        case .drive: return "externaldrive.connected.to.line.below"
        case .dropbox: return "shippingbox"
        case .onedrive: return "cloud"
        case .s3: return "server.rack"
        case .smb: return "network"
        }
    }

    /// Connexion par le navigateur (OAuth) ; S3 se contente de clés, le NAS d'un compte et d'un mot de passe.
    public var usesBrowser: Bool { self != .s3 && self != .smb }

    /// Clé du nom affiché (et du nom proposé pour la connexion).
    public var nameKey: String { "service.\(rawValue)" }

    public static func forType(_ type: String) -> CloudService? { CloudService(rawValue: type) }

    /// Réponses données à la place de l'utilisateur, par nom d'option de rclone.
    public static func autoAnswer(option: String) -> String? {
        switch option {
        case "config_shared_client_id": return "true"           // l'assistant a déjà expliqué l'identifiant partagé
        case "config_is_local": return "true"             // l'utilisateur a cliqué « Se connecter »
        case "config_change_team_drive": return "false"   // un Drive partagé se choisit plus tard, à la main
        case "config_drive_ok": return "true"
        default: return nil
        }
    }
}

public enum S3Provider: String, CaseIterable, Identifiable, Sendable {
    case aws = "AWS", cloudflare = "Cloudflare", wasabi = "Wasabi", minio = "Minio", other = "Other"
    public var id: String { rawValue }
    /// Hors AWS, l'adresse du service est demandée.
    public var needsEndpoint: Bool { self != .aws }
}
