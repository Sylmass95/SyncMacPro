import Foundation
import Observation

/// Dossiers favoris, partagés par les deux panneaux, conservés dans les réglages de l'app.
public final class FavoritesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "favoriteFolders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public func list() -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    public func contains(_ url: URL) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(normalized(url))
    }

    public func add(_ url: URL) {
        var paths = defaults.stringArray(forKey: key) ?? []
        let path = normalized(url)
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: key)
    }

    public func remove(_ url: URL) {
        let path = normalized(url)
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { $0 != path }, forKey: key)
    }
}

@MainActor
@Observable
public final class FavoritesModel {
    public private(set) var favorites: [URL]
    @ObservationIgnored private let store: FavoritesStore

    public init(store: FavoritesStore = FavoritesStore()) {
        self.store = store
        favorites = store.list()
    }

    public func add(_ url: URL) {
        store.add(url)
        favorites = store.list()
    }

    public func remove(_ url: URL) {
        store.remove(url)
        favorites = store.list()
    }

    public func contains(_ url: URL) -> Bool { store.contains(url) }
}
