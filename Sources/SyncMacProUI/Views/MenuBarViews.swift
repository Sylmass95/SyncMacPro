import SwiftUI
import SyncKit

/// Icône de la barre de menus : symbole selon l'état, et « 42 % » ou « 2 copies » pendant une copie.
public struct MenuBarLabel: View {
    let state: MenuBarState
    let localizer: Localizer

    public init(state: MenuBarState, localizer: Localizer = .system) {
        self.state = state
        self.localizer = localizer
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.systemImage)
            if let title = state.title(localizer) { Text(title).monospacedDigit() }
        }
    }
}

/// Panneau de la barre de menus : copies actives, prochaines exécutions, pause globale, ouvrir, quitter.
public struct MenuBarPanel: View {
    let model: AgentModel
    let text: CardText
    let onOpen: () -> Void
    let onQuit: () -> Void

    public init(model: AgentModel, text: CardText, onOpen: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.text = text
        self.onOpen = onOpen
        self.onQuit = onQuit
    }

    private var l: Localizer { text.localizer }
    private var tasks: [AgentTaskInfo] { model.status?.tasks ?? [] }
    private var active: [AgentTaskInfo] { tasks.filter { $0.state == .running || $0.state == .paused } }
    private var upcoming: [AgentTaskInfo] {
        let planned = tasks.filter { $0.nextDue != nil && $0.state != .disabled }
        return Array(planned.sorted { ($0.nextDue ?? .distantFuture) < ($1.nextDue ?? .distantFuture) }.prefix(3))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.connection != .connected {
                ConnectionBanner(
                    connection: model.connection, installState: .unknown, localizer: l,
                    onRetry: { model.restart() }, onInstall: {}
                )
            }
            section(l.text("menubar.active")) {
                if active.isEmpty {
                    Text(l.text("menubar.none")).foregroundStyle(.secondary)
                } else {
                    ForEach(active) { activeRow($0) }
                }
            }
            section(l.text("menubar.upcoming")) {
                if upcoming.isEmpty {
                    Text(l.text("menubar.nonext")).foregroundStyle(.secondary)
                } else {
                    ForEach(upcoming) { info in
                        HStack {
                            Text(info.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(text.nextRun(info.nextDue)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }
            Divider()
            pauseButton
            HStack {
                Button(l.text("menubar.open"), action: onOpen)
                Spacer()
                Button(l.text("menubar.quit"), action: onQuit)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func activeRow(_ info: AgentTaskInfo) -> some View {
        let progress = model.progress[info.id]
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(info.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(text.state(info.state)).font(.caption).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: Double(progress.overallPercent ?? 0) / 100)
                Text(text.progressLine(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var pauseButton: some View {
        let paused = model.status?.globalPause == true
        Button {
            Task { await model.setGlobalPause(!paused) }
        } label: {
            Label(
                paused ? l.text("dashboard.resume") : l.text("dashboard.pause.global"),
                systemImage: paused ? "play.fill" : "pause.fill"
            )
        }
        .disabled(model.globalPauseBusy || model.connection != .connected)
    }
}
