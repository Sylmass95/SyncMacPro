import Foundation

/// Les volumes montés et leurs allées et venues (DiskArbitration en réel, faux dans les tests).
public protocol DriveMonitor: Sendable {
    /// UUID de volume → point de montage, pour les volumes montés.
    func mountedVolumes() -> [String: String]
    /// Appelé à chaque montage ou démontage, depuis une file quelconque.
    func start(onChange: @escaping @Sendable () -> Void)
    /// `nil` si l'éjection a réussi, sinon le message de macOS.
    func eject(mountPath: String) async -> String?
    /// Date du montage du volume à ce point de montage, si on la connaît : un redémarrage de l'agent ne compte pas
    /// comme un branchement.
    func mountDate(path: String) -> Date?
}

extension DriveMonitor {
    public func mountDate(path: String) -> Date? { nil }
}

/// Le volume qui contient un chemin.
public struct VolumeInfo: Equatable, Sendable {
    public var uuid: String?
    public var name: String
    public var rootPath: String
    public var isInternal: Bool
    public var isNetwork: Bool
    /// Éjectable (clé USB, disque externe, image disque).
    public var isEjectable: Bool

    public init(uuid: String?, name: String, rootPath: String, isInternal: Bool, isNetwork: Bool, isEjectable: Bool = false) {
        self.isEjectable = isEjectable
        self.uuid = uuid
        self.name = name
        self.rootPath = rootPath
        self.isInternal = isInternal
        self.isNetwork = isNetwork
    }

    /// Disque externe qu'on peut débrancher : ni interne, ni réseau.
    public var isRemovable: Bool { (!isInternal || isEjectable) && !isNetwork }

    /// Chemin relatif à la racine du volume (« Sauvegardes/Photos »).
    public func relativePath(of path: String) -> String {
        let root = VolumeLookup.canonical(rootPath)
        let full = VolumeLookup.canonical(path)
        guard full.hasPrefix(root) else { return "" }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public enum VolumeLookup {
    /// Chemin réel, sans « / » final (`/var/…` → `/private/var/…`).
    public static func canonical(_ path: String) -> String {
        PathText.withoutTrailingSlash(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    public static func info(forPath path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsEjectableKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys), let root = values.volume else { return nil }
        return VolumeInfo(
            uuid: values.volumeUUIDString, name: values.volumeName ?? root.lastPathComponent,
            rootPath: canonical(root.path), isInternal: values.volumeIsInternal ?? true,
            isNetwork: !(values.volumeIsLocal ?? true), isEjectable: values.volumeIsEjectable ?? false
        )
    }
}
