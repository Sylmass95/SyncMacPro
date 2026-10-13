import Foundation
import SyncKit

/// Transforme une sélection de fichiers (ou un dépôt) en copies ponctuelles pour l'agent.
public enum OneOffPlanner {
    /// Une copie par dossier d'origine (un dépôt depuis le Finder peut mêler plusieurs dossiers).
    public static func copyTasks(
        items: [URL], to destination: URL, resolver: EndpointResolver = .system, localizer: Localizer = .system
    ) -> [SyncTask] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for item in items {
            let parent = item.standardizedFileURL.deletingLastPathComponent().path
            if groups[parent] == nil { order.append(parent) }
            groups[parent, default: []].append(item.lastPathComponent)
        }
        return order.map { parent in
            let names = (groups[parent] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let what = names.count == 1 ? names[0] : localizer.format("oneoff.items", names.count)
            var task = SyncTask(
                name: localizer.format("oneoff.copy.name", what, destination.lastPathComponent),
                source: resolver.endpoint(forPath: parent),
                destination: resolver.endpoint(forPath: destination.standardizedFileURL.path),
                sourceItems: names, mode: .copy, schedule: .manual
            )
            task.notifications = .always
            return task
        }
    }

    /// Le dossier de gauche entier vers celui de droite, en miroir. `acceptDeletions` : l'utilisateur a vu la simulation
    /// et accepte les suppressions qu'elle annonce (seuil à 100 % pour cette seule exécution).
    public static func syncTask(
        from source: URL, to destination: URL, acceptDeletions: Bool,
        resolver: EndpointResolver = .system, localizer: Localizer = .system
    ) -> SyncTask {
        var task = SyncTask(
            name: localizer.format("oneoff.sync.name", source.lastPathComponent, destination.lastPathComponent),
            source: resolver.endpoint(forPath: source.standardizedFileURL.path),
            destination: resolver.endpoint(forPath: destination.standardizedFileURL.path),
            mode: .mirror, schedule: .manual
        )
        task.notifications = .always
        if acceptDeletions { task.options.deleteThresholdPercent = 100 }
        return task
    }

    /// Ce qu'un dépôt dans `folder` peut copier : des fichiers locaux, ni déjà dans ce dossier, ni ce dossier ou un parent.
    public static func droppable(_ urls: [URL], into folder: URL) -> [URL] {
        let target = folder.standardizedFileURL.pathComponents
        return urls.filter { url in
            guard url.isFileURL else { return false }
            let item = url.standardizedFileURL
            if item.deletingLastPathComponent().pathComponents == target { return false }
            return !target.starts(with: item.pathComponents)
        }
    }
}

public enum CopyRequest: Equatable, Sendable {
    /// Des éléments choisis (ou déposés) vers un dossier.
    case copy(items: [URL], to: URL)
    /// Un dossier entier vers un autre, en miroir.
    case sync(from: URL, to: URL)
}

public struct CopySession: Identifiable {
    public let id = UUID()
    public let request: CopyRequest
    /// Ouverte depuis « Simuler » : la simulation démarre aussitôt.
    public let simulateAtOnce: Bool
}

extension OneOffPlanner {
    public static func tasks(
        for request: CopyRequest, acceptDeletions: Bool,
        resolver: EndpointResolver = .system, localizer: Localizer = .system
    ) -> [SyncTask] {
        switch request {
        case .copy(let items, let destination):
            return copyTasks(items: items, to: destination, resolver: resolver, localizer: localizer)
        case .sync(let source, let destination):
            return [syncTask(from: source, to: destination, acceptDeletions: acceptDeletions, resolver: resolver, localizer: localizer)]
        }
    }

    /// Les simulations des copies d'une même demande, additionnées ; le premier échec l'emporte, puis un blocage.
    public static func combine(_ outcomes: [SimulationOutcome]) -> SimulationOutcome {
        var total = SimulationResult(status: .succeeded, filesToTransfer: 0, bytesToTransfer: 0, deletions: 0, message: nil)
        for outcome in outcomes {
            switch outcome {
            case .failed(let message): return .failed(message)
            case .finished(let result):
                total.filesToTransfer += result.filesToTransfer
                total.bytesToTransfer += result.bytesToTransfer
                total.deletions += result.deletions
                if result.status != .succeeded && total.status == .succeeded {
                    total.status = result.status
                    total.message = result.message
                }
            }
        }
        return .finished(total)
    }
}

extension OneOffPlanner {
    /// Glisser un élément sélectionné emporte toute la sélection du panneau d'origine (SwiftUI ne glisse qu'un élément).
    public static func expandDrop(_ urls: [URL], selection: Set<URL>) -> [URL] {
        guard urls.count == 1, let dropped = urls.first, selection.contains(dropped), selection.count > 1 else { return urls }
        return selection.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Un dépôt dont rien ne peut être copié (dossier déposé dans lui-même, fichier déjà là) : à expliquer.
    public static func isRefusedDrop(_ urls: [URL], into folder: URL) -> Bool {
        !urls.isEmpty && droppable(urls, into: folder).isEmpty
    }
}
