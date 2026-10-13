import SwiftUI
import SyncKit

/// Ce que l'éditeur sait des connexions : la liste, l'ajout, la navigation dans un service.
struct RemoteContext {
    var remotes: [RemoteInfo]
    var onAdd: () -> Void
    var browse: (String, String) async -> FolderListing

    static let none = RemoteContext(remotes: [], onAdd: {}, browse: { _, _ in .loaded([]) })
}

enum RemotePath {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func join(_ parts: [String]) -> String { parts.joined(separator: "/") }

    static func parent(_ path: String) -> String { join(Array(components(path).dropLast())) }
}

/// Les sous-dossiers d'un dossier distant, sans défilement (rendu par les tests).
@MainActor
struct RemoteFolderListBody: View {
    let remote: String
    let path: String
    let listing: FolderListing?
    let localizer: Localizer
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(remote):\(path)").font(.callout.monospaced()).foregroundStyle(.secondary).padding(8)
            switch listing {
            case nil:
                HStack { ProgressView().controlSize(.small); Text(localizer.text("remote.loading")) }.padding(8)
            case .failed(let message)?:
                Label(localizer.format("remote.failed", message), systemImage: "xmark.circle.fill").foregroundStyle(.red).padding(8)
            case .loaded(let folders)?:
                if folders.isEmpty {
                    Text(localizer.text("remote.empty")).foregroundStyle(.secondary).padding(8)
                }
                ForEach(folders, id: \.self) { folder in
                    Button { onOpen(folder) } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                            Text(folder).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Feuille de choix d'un dossier dans un service en ligne : on descend, on remonte, on peut ajouter un nouveau dossier au bout.
@MainActor
struct RemoteFolderPicker: View {
    let remote: String
    let startPath: String
    let localizer: Localizer
    let browse: (String, String) async -> FolderListing
    let onChoose: (String) -> Void
    let onCancel: () -> Void
    @State private var path = ""
    @State private var listing: FolderListing?
    @State private var newFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.format("remote.title", remote)).font(.title3.bold())
            HStack {
                Button { open(RemotePath.parent(path)) } label: { Label(localizer.text("copy.up"), systemImage: "arrow.up") }
                    .disabled(path.isEmpty)
                Spacer()
            }
            ScrollView {
                RemoteFolderListBody(remote: remote, path: path, listing: listing, localizer: localizer) { folder in
                    open(RemotePath.join(RemotePath.components(path) + [folder]))
                }
            }
            .frame(minHeight: 220)
            .background(.background)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            TextField(localizer.text("remote.newFolder"), text: $newFolder).textFieldStyle(.roundedBorder)
            HStack {
                Button(localizer.text("confirm.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(localizer.text("remote.choose")) {
                    let extra = RemotePath.components(newFolder)
                    onChoose(RemotePath.join(RemotePath.components(path) + extra))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task(id: path) { listing = nil; listing = await browse(remote, path) }
        .onAppear { path = RemotePath.join(RemotePath.components(startPath)) }
    }

    private func open(_ next: String) {
        newFolder = ""
        path = next
    }
}
