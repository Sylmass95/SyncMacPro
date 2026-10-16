import Foundation

extension AgentCore {
    /// 1.6.4 : après une mise à jour, macOS ne reconnaît plus les autorisations de SyncMacPro ; l'app les efface puis
    /// demande ce passage : chaque dossier des tâches actives est listé, et macOS affiche ses demandes.
    public func checkAccess() async {
        var seen = Set<String>()
        var folders: [String] = []
        for task in tasks where task.isEnabled {
            for path in [task.source.filesystemPath, task.destination.filesystemPath].compactMap({ $0 }) where !path.isEmpty {
                let folder = TaskRunner.probedFolder(path)
                if seen.insert(folder).inserted { folders.append(folder) }
            }
        }
        log("demande d'accès à \(folders.count) dossier(s)")
        await configuration.touchAccess(folders)
    }
}
