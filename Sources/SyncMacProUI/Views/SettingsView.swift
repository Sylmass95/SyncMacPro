import AppKit
import SwiftUI
import SyncKit

@MainActor
public struct SettingsView: View {
    let installer: AgentInstaller
    let loginItem: LoginItemModel
    let localizer: Localizer
    let updates: UpdateModel?
    /// Agent pour les plafonds de débit ; `nil` : section Réseau absente (aperçus, tests).
    let model: AgentModel?
    @AppStorage("appearance") private var appearanceRaw = Appearance.auto.rawValue
    @AppStorage(GlassStyle.storageKey) private var styleRaw = GlassStyle.default.rawValue

    public init(
        installer: AgentInstaller, loginItem: LoginItemModel, localizer: Localizer = .system, updates: UpdateModel? = nil,
        model: AgentModel? = nil
    ) {
        self.model = model
        self.installer = installer
        self.loginItem = loginItem
        self.localizer = localizer
        self.updates = updates
    }

    public var body: some View {
        Form {
            Section(localizer.text("settings.appearance")) {
                Picker(localizer.text("settings.appearance"), selection: $appearanceRaw) {
                    Text(localizer.text("settings.appearance.auto")).tag(Appearance.auto.rawValue)
                    Text(localizer.text("settings.appearance.light")).tag(Appearance.light.rawValue)
                    Text(localizer.text("settings.appearance.dark")).tag(Appearance.dark.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker(localizer.text("settings.style"), selection: $styleRaw) {
                    Text(localizer.text("settings.style.vivid")).tag(GlassStyle.vivid.rawValue)
                    Text(localizer.text("settings.style.soft")).tag(GlassStyle.soft.rawValue)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle(
                    localizer.text("settings.login"),
                    isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) })
                )
                if let error = loginItem.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            }
            Section(localizer.text("settings.agent")) {
                LabeledContent(localizer.text("settings.agent"), value: stateLabel(installer.state))
                HStack {
                    if installer.state == .enabled {
                        Button(localizer.text("agent.uninstall")) { installer.uninstall() }
                    } else {
                        Button(localizer.text("agent.install")) { installer.install() }
                    }
                    if installer.state == .requiresApproval {
                        Button(localizer.text("agent.opensettings")) { installer.openSettings() }
                    }
                }
                if let error = installer.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            }
            if let model { NetworkSettingsSection(model: model, localizer: localizer) }
            Section(localizer.text("settings.data")) {
                Button(localizer.text("settings.data.reveal")) { revealData() }
            }
            Section(localizer.text("settings.about")) {
                Text(localizer.format("settings.version", version))
                if let updates {
                    if updates.isAvailable {
                        Toggle(localizer.text("update.automatic"), isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
                        Toggle(localizer.text("update.autoInstall"), isOn: Binding(get: { updates.autoInstall }, set: { updates.autoInstall = $0 }))
                        HStack {
                            Button(localizer.text("update.checkNow")) { updates.checkNow() }
                                .disabled(updates.state == .checking || updates.state == .installing)
                            Text(UpdateText(localizer: localizer).state(updates.state)).font(.callout).foregroundStyle(.secondary)
                            if updates.readyVersion != nil {
                                Button(localizer.text("update.install")) { updates.installNow() }
                            }
                        }
                    } else {
                        Text(localizer.text("update.unavailable")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(localizer.text("settings.licenses")) { openLicenses() }
                    Button(localizer.text("settings.source")) { NSWorkspace.shared.open(Self.repository) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(localizer.text("settings.title"))
        .onAppear {
            installer.refresh()
            loginItem.refresh()
        }
    }

    static let repository = URL(string: "https://github.com/Sylmass95/SyncMacPro")!

    private var version: String { AppInfo.version(executable: Bundle.main.executablePath ?? "") }

    /// Les licences des programmes embarqués (dans l'app ; sur GitHub en développement).
    private func openLicenses() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md", subdirectory: "Licenses") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(Self.repository.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
        }
    }

    private func stateLabel(_ state: AgentInstallState) -> String {
        switch state {
        case .enabled: return localizer.text("agent.state.enabled")
        case .notRegistered: return localizer.text("agent.state.notRegistered")
        case .requiresApproval: return localizer.text("agent.state.requiresApproval")
        case .notFound: return localizer.text("agent.state.notFound")
        case .unknown: return localizer.text("agent.state.unknown")
        }
    }

    private func revealData() {
        let folder = AgentPaths.standard.root
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
