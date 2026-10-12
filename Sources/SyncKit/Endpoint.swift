import Foundation

/// Un côté d'une synchronisation : dossier local, volume réseau ou service en ligne.
public enum Endpoint: Codable, Equatable, Hashable, Sendable {
    /// Dossier ou disque local.
    case local(path: String)
    /// Partage réseau (par exemple `smb://nas/partage`) déjà monté sur `mountPath`.
    case network(url: String, mountPath: String)
    /// Service en ligne géré par rclone (`remote` est le nom du « remote » rclone).
    case cloud(remote: String, path: String)

    public var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }

    /// Chemin sur le disque (dossier ou volume monté) ; `nil` pour un service en ligne.
    public var filesystemPath: String? {
        switch self {
        case .local(let path): return path
        case .network(_, let mountPath): return mountPath
        case .cloud: return nil
        }
    }

    /// Argument à donner à rclone : `remote:chemin` ou chemin local.
    public var rcloneSpec: String {
        switch self {
        case .local(let path): return path
        case .network(_, let mountPath): return mountPath
        case .cloud(let remote, let path): return "\(remote):\(path)"
        }
    }

    /// Le même endroit avec un sous-dossier en plus (par exemple pour un dossier d'archive).
    public func appending(_ component: String) -> Endpoint {
        switch self {
        case .local(let path): return .local(path: Endpoint.join(path, component))
        case .network(let url, let mountPath):
            return .network(url: url, mountPath: Endpoint.join(mountPath, component))
        case .cloud(let remote, let path): return .cloud(remote: remote, path: Endpoint.join(path, component))
        }
    }

    static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedComponent = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return "\(trimmedBase)/\(trimmedComponent)"
    }
}
