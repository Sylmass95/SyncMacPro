import Foundation
import Observation

public enum PaneProblem: Equatable, Sendable {
    /// Droits d'accès insuffisants.
    case unreadable
    /// Le dossier a disparu (volume démonté…) : le panneau est remonté au premier dossier existant.
    case vanished
}

/// Un panneau de fichiers : dossier courant, contenu, sélection.
@MainActor
@Observable
public final class PaneModel {
    public private(set) var folder: URL
    public private(set) var items: [DirectoryItem] = []
    public var selection: Set<URL> = []
    public private(set) var problem: PaneProblem?
    public var showHidden = false {
        didSet { reload() }
    }
    @ObservationIgnored private var anchor: URL?

    public init(folder: URL) {
        self.folder = folder
        reload()
    }

    public var canGoUp: Bool { folder.standardizedFileURL.path != "/" }

    public var selectedItems: [DirectoryItem] { items.filter { selection.contains($0.url) } }

    public func open(_ url: URL) {
        folder = url
        selection = []
        anchor = nil
        reload()
    }

    public func goUp() {
        guard canGoUp else { return }
        open(folder.deletingLastPathComponent())
    }

    public func reload() {
        problem = nil
        var target = folder
        if !FileManager.default.fileExists(atPath: target.path) {
            while !FileManager.default.fileExists(atPath: target.path) && target.path != "/" {
                target = target.deletingLastPathComponent()
            }
            folder = target
            problem = .vanished
        }
        do {
            items = try DirectoryLister.list(target, showHidden: showHidden)
        } catch {
            items = []
            problem = .unreadable
        }
        let existing = Set(items.map(\.url))
        selection = selection.filter { existing.contains($0) }
    }

    /// Clic simple : ne garde que l'élément ; ⌘ : l'ajoute ou le retire ; ⇧ : plage depuis le dernier clic.
    public func click(_ url: URL, command: Bool, shift: Bool) {
        if shift, let anchor, let from = items.firstIndex(where: { $0.url == anchor }),
           let to = items.firstIndex(where: { $0.url == url }) {
            let range = min(from, to)...max(from, to)
            selection = Set(items[range].map(\.url))
            return
        }
        if command {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            selection = [url]
        }
        anchor = url
    }

    public func selectAll() {
        selection = Set(items.map(\.url))
    }
}
