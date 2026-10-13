import AppKit
import SwiftUI

/// Premier lancement : propose d'installer l'agent d'arrière-plan.
@MainActor
public struct OnboardingView: View {
    let installer: AgentInstaller
    let localizer: Localizer
    let onInstall: () -> Void
    /// L'app tourne depuis le DMG ou une copie temporaire : l'agent ne peut pas s'installer durablement.
    let location: InstallLocationProblem?

    public init(
        installer: AgentInstaller, localizer: Localizer = .system, location: InstallLocationProblem? = nil,
        onInstall: @escaping () -> Void
    ) {
        self.installer = installer
        self.localizer = localizer
        self.location = location
        self.onInstall = onInstall
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(localizer.text("onboarding.title")).font(.largeTitle.bold())
            Text(localizer.text("onboarding.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            if let location {
                VStack(spacing: 8) {
                    Label(
                        localizer.text(location == .diskImage ? "onboarding.location.diskImage" : "onboarding.location.translocated"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    Button(localizer.text("onboarding.location.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            } else if installer.state == .requiresApproval {
                Text(localizer.text("onboarding.approve"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button(localizer.text("agent.opensettings")) { installer.openSettings() }
                    .buttonStyle(GlassButtonStyle(prominent: true))
            } else {
                Button(localizer.text("onboarding.install"), action: onInstall)
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .controlSize(.large)
            }
            if let error = installer.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
