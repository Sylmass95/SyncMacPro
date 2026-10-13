import AppKit
import SwiftUI
import SyncKit

@MainActor
public struct SettingsView: View {
    let installer: AgentInstaller
    let loginItem: LoginItemModel
    let localizer: Localizer
    @AppStorage("appearance") private var appearanceRaw = Appearance.auto.rawValue

    public init(installer: AgentInstaller, loginItem: LoginItemModel, localizer: Localizer = .system) {
        self.installer = installer
        self.loginItem = loginItem
        self.localizer = localizer
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
            Section(localizer.text("settings.data")) {
                Button(localizer.text("settings.data.reveal")) { revealData() }
            }
            Section(localizer.text("settings.about")) {
                Text(localizer.format("settings.version", version))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(localizer.text("settings.title"))
        .onAppear {
            installer.refresh()
            loginItem.refresh()
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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
