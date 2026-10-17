import Foundation
import NetFS

/// Monter un partage réseau (1.6.5) : la tâche n'échoue plus parce que le NAS a été démonté (coupure du réseau ou du
/// VPN, redémarrage du Mac).
public protocol ShareMounting: Sendable {
    /// Le point de montage du partage qui contient `mountPath` ; `nil` si l'app ne sait pas le monter elle-même.
    func root(of mountPath: String) -> String?
    /// Vrai si un volume est monté sur `root` (sans le lire : un partage figé ne bloque pas).
    func isMounted(_ root: String) -> Bool
    /// Monte le partage avec les identifiants du trousseau, sans fenêtre. Retourne l'erreur, `nil` si c'est fait.
    func mount(_ url: String, timeout: TimeInterval) async -> String?
}

public enum NetworkShare {
    /// `/Volumes/<partage>` pour un chemin dans un partage monté par macOS ; `nil` ailleurs.
    public static func volumesRoot(of mountPath: String) -> String? {
        let parts = mountPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }
}

extension Endpoint {
    /// Partage réseau que l'exécution sait monter : son absence n'empêche pas le départ.
    var isMountableShare: Bool {
        if case .network(_, let mountPath) = self { return NetworkShare.volumesRoot(of: mountPath) != nil }
        return false
    }
}

/// Un montage à la fois par point de montage, pour tout l'agent (1.6.6).
actor ShareMountGate {
    static let shared = ShareMountGate()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ root: String) async {
        guard waiters[root] != nil else { waiters[root] = []; return }
        await withCheckedContinuation { waiters[root, default: []].append($0) }
    }

    func release(_ root: String) {
        guard var queue = waiters[root], !queue.isEmpty else { waiters[root] = nil; return }
        let next = queue.removeFirst()
        waiters[root] = queue
        next.resume()
    }
}

/// Montage par NetFS, comme le Finder (« Se connecter au serveur »).
public struct NetFSShareMounter: ShareMounting {
    /// NetFS rappelle sur cette file sans la retenir : elle doit vivre aussi longtemps que l'agent (une file locale,
    /// libérée au retour de l'appel, plantait le processus — essai réel du 17/10).
    private static let callbacks = DispatchQueue(label: "syncmacpro.mount")

    public init() {}

    public func root(of mountPath: String) -> String? { NetworkShare.volumesRoot(of: mountPath) }

    public func isMounted(_ root: String) -> Bool {
        // `getmntinfo` partage un tampon entre les appels : deux tâches qui démarrent ensemble s'y marcheraient dessus.
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        defer { free(mounts) }
        guard count > 0, let mounts else { return false }
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let path = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if path == root { return true }
        }
        return false
    }

    public func mount(_ url: String, timeout: TimeInterval) async -> String? {
        guard let address = URL(string: url) else { return "adresse « \(url) » invalide" }
        return await withCheckedContinuation { continuation in
            let done = Locked(false)
            let finish: @Sendable (String?) -> Void = { error in
                var first = false
                done.update { already in first = !already; already = true }
                if first { continuation.resume(returning: error) }
            }
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            let mountOptions = NSMutableDictionary()
            var request: AsyncRequestID?
            let status = NetFSMountURLAsync(address as CFURL, nil, nil, nil, openOptions, mountOptions, &request, Self.callbacks) { code, _, _ in
                finish(Self.describe(code))
            }
            if status != 0 { finish(Self.describe(status)); return }
            let pending = request
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !done.get() else { return }   // déjà fini : la demande n'existe plus, ne pas l'annuler
                if let pending { NetFSMountURLCancel(pending) }
                finish("pas de réponse du serveur en \(Int(timeout)) s")
            }
        }
    }

    /// 0 et « déjà monté » : réussite ; sinon le texte de l'erreur.
    static func describe(_ code: Int32) -> String? {
        if code == 0 || code == EEXIST { return nil }
        if code > 0, let text = strerror(code) { return String(cString: text) }
        return "erreur \(code)"
    }
}
