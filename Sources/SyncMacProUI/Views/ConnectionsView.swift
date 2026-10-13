import SwiftUI
import SyncKit

public struct ConnectionRowState: Equatable, Sendable {
    public var testing: Bool
    public var result: RemoteTestResult?

    public init(testing: Bool, result: RemoteTestResult?) {
        self.testing = testing
        self.result = result
    }
}

/// La liste des connexions, sans défilement (rendue par les tests).
@MainActor
struct ConnectionsListBody: View {
    let remotes: [RemoteInfo]
    let usage: [String: [String]]
    let rows: [String: ConnectionRowState]
    let error: String?
    let offline: Bool
    let localizer: Localizer
    let onTest: (RemoteInfo) -> Void
    let onReconnect: (RemoteInfo) -> Void
    let onDelete: (RemoteInfo) -> Void

    static func serviceName(_ type: String, localizer: Localizer) -> String {
        CloudService.forType(type).map { localizer.text($0.nameKey) } ?? type
    }

    /// Les services à jeton peuvent être reconnectés (jeton expiré ou révoqué).
    static func canReconnect(_ type: String) -> Bool {
        CloudService.forType(type)?.usesBrowser ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if remotes.isEmpty && error == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizer.text("connections.empty.title")).font(.headline)
                    Text(localizer.text("connections.empty.body")).foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            }
            ForEach(remotes) { remote in row(remote) }
        }
    }

    private func row(_ remote: RemoteInfo) -> some View {
        let state = rows[remote.name]
        let users = usage[remote.name] ?? []
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: CloudService.forType(remote.type)?.symbol ?? "externaldrive.badge.icloud")
                .font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name).font(.headline)
                Text(Self.serviceName(remote.type, localizer: localizer)).font(.caption).foregroundStyle(.secondary)
                Text(users.isEmpty ? localizer.text("connections.unused") : localizer.format("connections.usedBy", users.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let state { status(state) }
            }
            Spacer(minLength: 8)
            Button(localizer.text("connections.test")) { onTest(remote) }.disabled(offline || state?.testing == true)
            if Self.canReconnect(remote.type) {
                Button(localizer.text("connections.reconnect")) { onReconnect(remote) }.disabled(offline)
            }
            Button(role: .destructive) { onDelete(remote) } label: { Image(systemName: "trash") }
                .disabled(offline).help(localizer.text("connections.delete"))
        }
        .controlSize(.small)
        .padding(12)
        .glassCard(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func status(_ state: ConnectionRowState) -> some View {
        if state.testing {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(localizer.text("connections.testing")) }.font(.caption)
        } else if let result = state.result {
            Label(
                result.ok ? localizer.text("connections.ok") : localizer.format("connections.failed", result.message ?? ""),
                systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.caption).foregroundStyle(result.ok ? .green : .red).lineLimit(3)
        }
    }
}

/// L'écran Connexions : liste, Ajouter, Tester, Reconnecter, Supprimer.
@MainActor
struct ConnectionsView: View {
    let model: AgentModel
    let localizer: Localizer
    @State private var rows: [String: ConnectionRowState] = [:]
    @State private var wizard: WizardModel?
    @State private var deleting: RemoteInfo?
    @State private var refusal: String?

    private var offline: Bool { model.connection != .connected }

    private var usage: [String: [String]] {
        Dictionary(uniqueKeysWithValues: model.remotes.map { ($0.name, model.tasks(usingRemote: $0.name).map(\.name)) })
    }

    var body: some View {
        ScrollView {
            ConnectionsListBody(
                remotes: model.remotes, usage: usage, rows: rows, error: model.remotesError, offline: offline,
                localizer: localizer,
                onTest: { remote in Task { await test(remote) } },
                onReconnect: { remote in wizard = WizardModel(reconnecting: remote, model: model, localizer: localizer) },
                onDelete: { deleting = $0 }
            )
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(localizer.text("sidebar.connections"))
        .toolbar {
            Button { wizard = WizardModel(model: model, localizer: localizer) } label: {
                Label(localizer.text("connections.add"), systemImage: "plus")
            }
            .disabled(offline)
        }
        .task { await model.reloadRemotes() }
        .sheet(item: Binding(get: { wizard.map(WizardSession.init) }, set: { if $0 == nil { wizard = nil } })) { session in
            ConnectionWizardView(wizard: session.wizard, localizer: localizer) {
                wizard = nil
                Task { await model.reloadRemotes() }
            }
        }
        .confirmationDialog(
            localizer.format("connections.delete.confirm", deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(localizer.text("connections.delete"), role: .destructive) {
                if let remote = deleting { Task { refusal = await model.deleteRemote(remote.name) } }
            }
        }
        .alert(localizer.text("alert.title"), isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button(localizer.text("alert.ok")) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    private func test(_ remote: RemoteInfo) async {
        rows[remote.name] = ConnectionRowState(testing: true, result: nil)
        let result = await model.testRemote(remote.name)
        rows[remote.name] = ConnectionRowState(testing: false, result: result)
    }
}

/// Enveloppe identifiable d'un assistant ouvert (pour `.sheet(item:)`).
struct WizardSession: Identifiable {
    let wizard: WizardModel
    var id: ObjectIdentifier { ObjectIdentifier(wizard) }
}
