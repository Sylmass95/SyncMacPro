import AppKit
import SwiftUI
import SyncKit

/// Les actions du menu contextuel d'un élément (`nil` : entrée absente).
struct PaneMenu {
    let copyToOther: () -> Void
    let simulate: () -> Void
    let open: (() -> Void)?
    let addFavorite: (() -> Void)?
    let reveal: () -> Void
}

/// La barre de chemin : le volume, puis chaque dossier, cliquables.
@MainActor
struct PathBar: View {
    let crumbs: [Crumb]
    let onOpen: (URL) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                Button(crumb.name) { onOpen(crumb.url) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// La liste d'un panneau, sans défilement (rendue par les tests).
@MainActor
struct FileListBody: View {
    let items: [DirectoryItem]
    let selection: Set<URL>
    let problem: PaneProblem?
    let localizer: Localizer
    let onClick: (URL, Bool, Bool) -> Void
    let onOpen: (DirectoryItem) -> Void
    let menu: (DirectoryItem) -> PaneMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem {
                Label(localizer.text(problem == .unreadable ? "copy.pane.unreadable" : "copy.pane.vanished"),
                      systemImage: problem == .unreadable ? "lock.fill" : "externaldrive.badge.xmark")
                    .font(.callout)
                    .foregroundStyle(problem == .unreadable ? .red : .orange)
                    .padding(10)
            }
            if items.isEmpty && problem != .unreadable {
                Text(localizer.text("copy.pane.empty")).font(.callout).foregroundStyle(.secondary).padding(10)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in row(item) }
            }
        }
    }

    private func row(_ item: DirectoryItem) -> some View {
        let selected = selection.contains(item.url)
        let actions = menu(item)
        return HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.size.map { localizer.bytes($0) } ?? "—")
                .foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(item.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "")
                .foregroundStyle(.secondary).monospacedDigit().frame(width: 130, alignment: .trailing)
        }
        .font(.callout)
        .opacity(item.isHidden ? 0.6 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(item) }
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSEvent.modifierFlags
            onClick(item.url, flags.contains(.command), flags.contains(.shift))
        })
        .draggable(item.url)
        .contextMenu {
            Button(localizer.text("copy.menu.copy"), action: actions.copyToOther)
            Button(localizer.text("copy.menu.simulate"), action: actions.simulate)
            if let open = actions.open { Button(localizer.text("copy.menu.open"), action: open) }
            if let add = actions.addFavorite { Button(localizer.text("copy.menu.favorite"), action: add) }
            Divider()
            Button(localizer.text("copy.menu.reveal"), action: actions.reveal)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Un panneau complet : emplacements, dossier parent, fichiers cachés, barre de chemin, liste, dépôt.
@MainActor
struct FilePaneView: View {
    let pane: PaneModel
    let favorites: FavoritesModel
    let localizer: Localizer
    let onDrop: ([URL]) -> Void
    let menu: (DirectoryItem) -> PaneMenu
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PathBar(crumbs: PathCrumbs.crumbs(for: pane.folder), onOpen: pane.open)
            Divider()
            ScrollView {
                FileListBody(
                    items: pane.items, selection: pane.selection, problem: pane.problem, localizer: localizer,
                    onClick: { pane.click($0, command: $1, shift: $2) },
                    onOpen: { item in
                        if item.isDirectory { pane.open(item.url) } else { NSWorkspace.shared.open(item.url) }
                    },
                    menu: menu
                )
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return true
            } isTargeted: { targeted = $0 }
        }
        .background(.background)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                lineWidth: targeted ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                Section(localizer.text("copy.places.favorites")) {
                    if favorites.favorites.isEmpty { Text(localizer.text("copy.places.noFavorites")) }
                    ForEach(favorites.favorites, id: \.self) { url in
                        Button(url.lastPathComponent) { pane.open(url) }
                    }
                }
                Section(localizer.text("copy.places.standard")) {
                    ForEach(StandardLocations.folders()) { place in
                        Button { pane.open(place.url) } label: { Label(place.name, systemImage: place.systemImage) }
                    }
                }
                Section(localizer.text("copy.places.volumes")) {
                    ForEach(StandardLocations.volumes()) { place in
                        Button { pane.open(place.url) } label: { Label(place.name, systemImage: place.systemImage) }
                    }
                }
            } label: {
                Label(pane.folder.lastPathComponent.isEmpty ? "/" : pane.folder.lastPathComponent, systemImage: "folder")
            }
            .fixedSize()
            Spacer()
            Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!pane.canGoUp).help(localizer.text("copy.up"))
            Button {
                if favorites.contains(pane.folder) { favorites.remove(pane.folder) } else { favorites.add(pane.folder) }
            } label: {
                Image(systemName: favorites.contains(pane.folder) ? "star.fill" : "star")
            }
            .help(localizer.text("copy.favorite.toggle"))
            Toggle(isOn: Binding(get: { pane.showHidden }, set: { pane.showHidden = $0 })) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button).help(localizer.text("copy.hidden"))
            Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }.help(localizer.text("copy.reload"))
        }
        .controlSize(.small)
        .padding(8)
    }
}
