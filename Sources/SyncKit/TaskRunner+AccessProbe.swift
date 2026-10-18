import Foundation

/// Sonde d'accès (1.6.2). Après une mise à jour, la signature ad hoc de l'agent change et macOS redemande l'accès aux
/// dossiers protégés (Bureau, Documents, disques…) : rsync attendait alors la réponse sans rien dire (essai réel :
/// 2 h 13 jusqu'au clic). Lister chaque dossier avant le moteur fait apparaître la demande et la signale vite.
extension TaskRunner {
    /// Le dossier à sonder : le chemin, ou son premier parent existant (destination pas encore créée).
    static func probedFolder(_ path: String) -> String {
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/", !current.isEmpty {
            current = (current as NSString).deletingLastPathComponent
        }
        return VolumeLookup.canonical(current.isEmpty ? "/" : current)
    }

    /// Message d'échec si un dossier ne répond pas dans le délai ; `nil` sinon (une autre erreur est laissée au moteur).
    func probeAccess(_ task: SyncTask) async -> String? {
        for path in [task.source.filesystemPath, task.destination.filesystemPath].compactMap({ $0 }) where !path.isEmpty {
            let folder = Self.probedFolder(path)
            if !(await answers(folder)) { return Self.accessMessage(folder) }
        }
        return nil
    }

    func answers(_ folder: String) async -> Bool {
        let (executable, arguments) = configuration.accessProbe(folder)
        return await AccessProbe.answers(executable: executable, arguments: arguments, timeout: configuration.accessProbeTimeout)
    }

    /// Partages réseau (1.6.5) : montés s'il le faut, puis sondés. Rend le nom du partage injoignable et le message.
    func prepareShares(_ task: SyncTask) async -> (share: String, message: String)? {
        for endpoint in [task.source, task.destination] {
            guard case .network(let url, let mountPath) = endpoint, let root = configuration.shares.root(of: mountPath) else { continue }
            let name = (root as NSString).lastPathComponent
            if !configuration.shares.isMounted(root) {
                // Une seule tentative à la fois par partage : deux tâches qui partent ensemble le montaient deux fois
                // (« Documents » et « Documents-1 », 1.6.6). La seconde attend et profite du premier montage.
                await ShareMountGate.shared.acquire(root)
                var error: String?
                if !configuration.shares.isMounted(root) {
                    error = await configuration.shares.mount(url, timeout: configuration.shareMountTimeout)
                }
                await ShareMountGate.shared.release(root)
                guard configuration.shares.isMounted(root) else {
                    return (name, Self.unmountedMessage(name, error: error ?? "monté à un autre endroit que \(root)"))
                }
            }
            if !(await answers(root)) { return (name, Self.silentShareMessage(name)) }
        }
        return nil
    }

    /// Surveille les partages réseau de la tâche pendant la copie ; le premier qui disparaît arrête l'exécution.
    func watchShares(_ task: SyncTask, lost: Locked<String?>) -> Task<Void, Never>? {
        let roots: [(String, String)] = [task.source, task.destination].compactMap { endpoint in
            guard case .network(_, let mountPath) = endpoint, let root = configuration.shares.root(of: mountPath) else { return nil }
            return ((root as NSString).lastPathComponent, root)
        }
        guard !roots.isEmpty, configuration.shareWatchInterval > 0 else { return nil }
        let shares = configuration.shares, control = self.control
        let delay = UInt64(configuration.shareWatchInterval * 1_000_000_000)
        return Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled || control.stopRequested { return }
                if let gone = roots.first(where: { !shares.isMounted($0.1) }) {
                    lost.set(gone.0)
                    control.stop()
                    return
                }
            }
        }
    }

    static func lostShareMessage(_ name: String) -> String {
        "Partage réseau « \(name) » démonté pendant la copie (NAS éteint ou réseau / VPN coupé) : la copie s'est arrêtée, "
            + "elle reprendra quand le NAS répondra."
    }

    static func unmountedMessage(_ name: String, error: String) -> String {
        "Partage réseau « \(name) » non monté, montage impossible (\(error)) : NAS éteint, en veille ou réseau (VPN) coupé ? "
            + "Nouvel essai plus tard."
    }

    static func silentShareMessage(_ name: String) -> String {
        "Partage réseau « \(name) » monté mais il ne répond pas : NAS éteint, en veille ou réseau (VPN) coupé ? Si une fenêtre "
            + "de macOS demande l'accès aux volumes réseau, acceptez-la. Nouvel essai plus tard."
    }

    static func accessMessage(_ folder: String) -> String {
        let name = FileManager.default.displayName(atPath: folder)
        return "« \(name) » ne répond pas : macOS attend sans doute que vous autorisiez SyncMacPro à y accéder (une fenêtre "
            + "« … souhaite accéder … » est peut-être ouverte, parfois derrière les autres). Acceptez-la : la tâche sera "
            + "retentée. Sinon, le disque ou le NAS ne répond pas."
    }
}
