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
    /// Vrai pendant la lecture du dossier (faite hors du fil principal : un NAS lent ne fige pas l'app).
    public private(set) var isLoading = false
    public var showHidden = false {
        didSet { reload() }
    }
    @ObservationIgnored private var anchor: URL?

    public typealias Lister = @Sendable (URL, Bool) throws -> [DirectoryItem]
    @ObservationIgnored private let lister: Lister
    @ObservationIgnored private let exists: @Sendable (URL) -> Bool
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?

    public init(
        folder: URL,
        lister: @escaping Lister = { try DirectoryLister.list($0, showHidden: $1) },
        exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.folder = folder
        self.lister = lister
        self.exists = exists
        reload()
    }

    public var canGoUp: Bool { folder.standardizedFileURL.path != "/" }

    public var selectedItems: [DirectoryItem] { items.filter { selection.contains($0.url) } }

    public func open(_ url: URL) {
        folder = url
        selection = []
        anchor = nil
        items = []   // pas d'éléments de l'ancien dossier sous le titre du nouveau pendant la lecture
        reload()
    }

    public func goUp() {
        guard canGoUp else { return }
        open(folder.deletingLastPathComponent())
    }

    /// Attend la fin de la lecture en cours (tests, enchaînements).
    public func settled() async {
        while let current = loading {
            await current.value
            if loading == nil || current == loading { break }
        }
    }

    private struct Listing: Sendable {
        let folder: URL
        let items: [DirectoryItem]
        let problem: PaneProblem?
    }

    /// Relit le dossier hors du fil principal ; une lecture plus ancienne qui finirait après est ignorée.
    public func reload() {
        generation += 1
        let current = generation, target = folder, hidden = showHidden
        let lister = self.lister, exists = self.exists
        isLoading = true
        loading = Task {
            let listing = await Task.detached(priority: .userInitiated) { () -> Listing in
                var folder = target
                var problem: PaneProblem?
                if !exists(folder) {
                    while !exists(folder) && folder.path != "/" { folder = folder.deletingLastPathComponent() }
                    problem = .vanished
                }
                do {
                    return Listing(folder: folder, items: try lister(folder, hidden), problem: problem)
                } catch {
                    return Listing(folder: folder, items: [], problem: .unreadable)
                }
            }.value
            guard current == self.generation else { return }
            self.folder = listing.folder
            self.items = listing.items
            self.problem = listing.problem
            let existing = Set(listing.items.map(\.url))
            self.selection = self.selection.filter { existing.contains($0) }
            self.isLoading = false
            self.loading = nil
        }
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
