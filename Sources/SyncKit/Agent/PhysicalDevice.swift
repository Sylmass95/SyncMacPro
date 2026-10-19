import Foundation

/// Disque physique d'un lieu (1.7.0) : deux copies ne tournent pas en même temps sur un même disque, en source comme en
/// destination. `nil` : pas de limite (SSD interne du Mac, services en ligne).
public enum PhysicalDevice {
    /// Partage réseau : son serveur (tous les partages d'un même NAS comptent pour un disque).
    public static func networkKey(url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return "net:" + host.lowercased()
    }

    /// D'après la source d'un montage (`/dev/disk6s1`, `//moi@nas/partage`) : le disque entier ou le serveur.
    public static func wholeDisk(fromDevice device: String) -> String? {
        if device.hasPrefix("//") {
            let rest = device.dropFirst(2)
            let hostPart = rest.split(separator: "/").first.map(String.init) ?? ""
            let host = hostPart.split(separator: "@").last.map(String.init) ?? hostPart
            return host.isEmpty ? nil : "net:" + host.lowercased()
        }
        guard device.hasPrefix("/dev/disk") else { return nil }
        let name = String(device.dropFirst("/dev/".count))   // disk6s1
        let digits = name.dropFirst(4).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk:disk" + digits
    }

    /// Volume monté sous `/Volumes/<X>` qui porte ce chemin : la source de son montage, sans le lire (un partage figé ne
    /// bloque pas). Hors de `/Volumes` (disque de démarrage) : `nil`.
    public static func local(path: String) -> String? {
        guard let root = NetworkShare.volumesRoot(of: path) else { return nil }
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        defer { free(mounts) }
        guard count > 0, let mounts else { return nil }
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard on == root else { continue }
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return wholeDisk(fromDevice: from)
        }
        return nil
    }
}
