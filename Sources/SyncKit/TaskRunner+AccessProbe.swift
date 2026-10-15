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
            let (executable, arguments) = configuration.accessProbe(folder)
            guard let process = try? ProcessRunner.spawn(executable: executable, arguments: arguments, onLine: { _ in }) else { continue }
            let timedOut = Locked(false)
            let delay = UInt64(max(0, configuration.accessProbeTimeout) * 1_000_000_000)
            let timer = Task {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                timedOut.set(true)
                process.terminate(killAfter: 2)
            }
            _ = await process.waitForExit()
            timer.cancel()
            if timedOut.get() { return Self.accessMessage(folder) }
        }
        return nil
    }

    static func accessMessage(_ folder: String) -> String {
        let name = FileManager.default.displayName(atPath: folder)
        return "« \(name) » ne répond pas : macOS attend sans doute que vous autorisiez SyncMacPro à y accéder (une fenêtre "
            + "« … souhaite accéder … » est peut-être ouverte, parfois derrière les autres). Acceptez-la : la tâche sera "
            + "retentée. Sinon, le disque ou le NAS ne répond pas."
    }
}
