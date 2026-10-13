import AppKit
import SwiftUI
import SyncKit

/// L'écran Copie : deux panneaux (gauche = source, droite = destination) et les actions entre eux.
@MainActor
struct CopyView: View {
    let model: AgentModel
    let localizer: Localizer
    let onSaveAsTask: (TaskDraft) -> Void
    @State private var left = PaneModel(folder: URL(fileURLWithPath: NSHomeDirectory()))
    @State private var right = PaneModel(folder: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop"))
    @State private var favorites = FavoritesModel()
    @State private var size: SizeState = .none
    @State private var session: CopySession?
    @State private var dropRefused = false

    private var offline: Bool { model.connection != .connected }
    private var selected: [URL] { left.selectedItems.map(\.url) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                pane(left, other: right)
                actions
                pane(right, other: left)
            }
            .padding(12)
            Divider()
            CopyStatusBar(count: selected.count, size: size, free: FreeSpace.available(at: right.folder), localizer: localizer)
        }
        .navigationTitle(localizer.text("sidebar.copy"))
        // La taille de la sélection est recalculée (et l'ancien calcul annulé) dès qu'elle change.
        .task(id: left.selection) { await computeSize() }
        // Un disque démonté pendant la navigation : les panneaux remontent au premier dossier existant.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            left.reload()
            right.reload()
        }
        .alert(localizer.text("copy.drop.refused.title"), isPresented: $dropRefused) {
            Button(localizer.text("alert.ok")) {}
        } message: {
            Text(localizer.text("copy.drop.refused.body"))
        }
        .sheet(item: $session) { current in
            CopyConfirmationView(model: model, session: current, localizer: localizer) { session = nil }
        }
    }

    private func pane(_ pane: PaneModel, other: PaneModel) -> some View {
        FilePaneView(
            pane: pane, favorites: favorites, localizer: localizer,
            onDrop: { dropped in
                let urls = OneOffPlanner.expandDrop(dropped, selection: other.selection)
                let accepted = OneOffPlanner.droppable(urls, into: pane.folder)
                guard !accepted.isEmpty else {
                    if OneOffPlanner.isRefusedDrop(urls, into: pane.folder) { dropRefused = true }
                    return
                }
                session = CopySession(request: .copy(items: accepted, to: pane.folder), simulateAtOnce: false)
            },
            menu: { item in
                let targets = pane.selection.contains(item.url) ? pane.selectedItems.map(\.url) : [item.url]
                return PaneMenu(
                    copyToOther: { session = CopySession(request: .copy(items: targets, to: other.folder), simulateAtOnce: false) },
                    simulate: { session = CopySession(request: .copy(items: targets, to: other.folder), simulateAtOnce: true) },
                    open: item.isDirectory ? { pane.open(item.url) } : nil,
                    addFavorite: item.isDirectory ? { favorites.add(item.url) } : nil,
                    reveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                )
            }
        )
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Spacer()
            Button { copy(simulate: false) } label: { Label(localizer.text("copy.action.copy"), systemImage: "arrow.right") }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(selected.isEmpty || offline)
                .help(localizer.text("copy.action.copy.help"))
            Button { session = CopySession(request: .sync(from: left.folder, to: right.folder), simulateAtOnce: false) } label: {
                Label(localizer.text("copy.action.sync"), systemImage: "arrow.right.circle")
            }
            .disabled(offline)
            .help(localizer.text("copy.action.sync.help"))
            Button { simulate() } label: { Label(localizer.text("copy.action.simulate"), systemImage: "eye") }
                .disabled(offline)
            Button { saveAsTask() } label: { Label(localizer.text("copy.action.save"), systemImage: "square.and.arrow.down") }
            Divider().frame(width: 40)
            Button { swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                .help(localizer.text("copy.action.swap"))
            if offline {
                Text(localizer.text("copy.offline")).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(width: 124)
            }
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(GlassButtonStyle(prominent: false))
        .frame(width: 172)
    }

    private func copy(simulate: Bool) {
        guard !selected.isEmpty else { return }
        session = CopySession(request: .copy(items: selected, to: right.folder), simulateAtOnce: simulate)
    }

    /// Simuler : la sélection si elle existe, sinon la synchronisation du dossier entier.
    private func simulate() {
        if selected.isEmpty {
            session = CopySession(request: .sync(from: left.folder, to: right.folder), simulateAtOnce: true)
        } else {
            copy(simulate: true)
        }
    }

    /// Enregistrer comme tâche : la sélection (mode copie) ou, sans sélection, tout le dossier (mode copie aussi :
    /// le miroir reste un choix explicite dans l'éditeur).
    private func saveAsTask() {
        let task = selected.isEmpty
            ? OneOffPlanner.copyTasks(items: [left.folder], to: right.folder, localizer: localizer)[0].withWholeFolder(left.folder)
            : OneOffPlanner.copyTasks(items: selected, to: right.folder, localizer: localizer)[0]
        var draft = TaskDraft(task: task)
        draft.name = ""
        onSaveAsTask(draft)
    }

    private func swap() {
        let leftFolder = left.folder
        left.open(right.folder)
        right.open(leftFolder)
    }

    private func computeSize() async {
        let urls = selected
        guard !urls.isEmpty else { size = .none; return }
        size = .computing
        let work = Task.detached(priority: .utility) { try FolderSizer.total(of: urls) }
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let total): size = .done(total)
        case .failure: size = .failed
        }
    }
}

private extension SyncTask {
    /// Une tâche « tout le dossier » : source = le dossier, aucun élément choisi.
    func withWholeFolder(_ folder: URL) -> SyncTask {
        var task = self
        task.source = EndpointResolver.system.endpoint(forPath: folder.standardizedFileURL.path)
        task.sourceItems = []
        return task
    }
}
