import Foundation

public struct Place: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let systemImage: String
    public var id: URL { url }
}

public enum StandardLocations {
    /// Départ, Bureau, Documents, Téléchargements (noms affichés par le Finder).
    public static func folders() -> [Place] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates: [(URL, String)] = [
            (home, "house"),
            (home.appendingPathComponent("Desktop"), "desktopcomputer"),
            (home.appendingPathComponent("Documents"), "doc"),
            (home.appendingPathComponent("Downloads"), "arrow.down.circle"),
        ]
        return candidates.compactMap { url, image in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Place(url: url, name: FileManager.default.displayName(atPath: url.path), systemImage: image)
        }
    }

    /// Volumes montés visibles (disque de démarrage, disques externes, partages réseau).
    public static func volumes() -> [Place] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsLocalKey], options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey])
            let network = values?.volumeIsLocal == false
            return Place(
                url: url, name: values?.volumeName ?? url.lastPathComponent,
                systemImage: network ? "network" : "externaldrive"
            )
        }
    }
}
