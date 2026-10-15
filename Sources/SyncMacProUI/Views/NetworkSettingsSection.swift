import SwiftUI
import SyncKit

/// Réglages › Réseau : plafonds de réception et d'envoi internet et du réseau local, en Mbit/s, appliqués à chaud.
@MainActor
public struct NetworkSettingsSection: View {
    let model: AgentModel
    let localizer: Localizer
    @State private var draft: BandwidthDraft
    @State private var edited = false

    public init(model: AgentModel, localizer: Localizer) {
        self.model = model
        self.localizer = localizer
        _draft = State(initialValue: BandwidthDraft(model.bandwidth))
    }

    public var body: some View {
        Section(localizer.text("settings.network")) {
            row("network.download", on: $draft.downloadOn, text: $draft.downloadText)
            row("network.upload", on: $draft.uploadOn, text: $draft.uploadText)
            row("network.local", on: $draft.localOn, text: $draft.localText)
            if draft.limits == nil {
                Text(localizer.text("network.invalid")).font(.callout).foregroundStyle(.red)
            }
            Text(localizer.text("network.help")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.connection != .connected && model.bandwidth == nil)
        .onChange(of: draft) { _, new in
            edited = true
            if let limits = new.limits, limits != model.bandwidth { model.setBandwidth(limits) }
        }
        .onChange(of: model.bandwidth) { _, new in
            // Valeur changée ailleurs (ctl, autre fenêtre) : reprise tant que l'utilisateur n'a rien saisi ici.
            if !edited { draft = BandwidthDraft(new) }
        }
    }

    private func row(_ key: String, on: Binding<Bool>, text: Binding<String>) -> some View {
        HStack {
            Toggle(localizer.text(key), isOn: on)
            Spacer()
            TextField("", text: text, prompt: Text("100"))
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .disabled(!on.wrappedValue)
            Text(localizer.text("network.unit")).foregroundStyle(.secondary)
        }
    }
}
