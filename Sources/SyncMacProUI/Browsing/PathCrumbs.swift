import Foundation

public struct Crumb: Hashable, Sendable {
    public let name: String
    public let url: URL
}

/// La barre de chemin : le volume, puis chaque dossier.
public enum PathCrumbs {
    public static func systemVolumeName(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    public static func crumbs(for url: URL, volumeName: (URL) -> String? = systemVolumeName) -> [Crumb] {
        let parts = url.standardizedFileURL.pathComponents
        var crumbs: [Crumb] = []
        var current: URL
        var rest: ArraySlice<String>
        if parts.count >= 3, parts[1] == "Volumes" {
            current = URL(fileURLWithPath: "/Volumes/\(parts[2])")
            crumbs.append(Crumb(name: parts[2], url: current))
            rest = parts.dropFirst(3)
        } else {
            current = URL(fileURLWithPath: "/")
            crumbs.append(Crumb(name: volumeName(current) ?? "/", url: current))
            rest = parts.dropFirst(1)
        }
        for part in rest {
            current.appendPathComponent(part)
            crumbs.append(Crumb(name: part, url: current))
        }
        return crumbs
    }
}
