import SwiftUI

/// Premier lancement : propose d'installer l'agent d'arrière-plan.
public struct OnboardingView: View {
    let installer: AgentInstaller
    let localizer: Localizer
    let onInstall: () -> Void

    public init(installer: AgentInstaller, localizer: Localizer = .system, onInstall: @escaping () -> Void) {
        self.installer = installer
        self.localizer = localizer
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
            if installer.state == .requiresApproval {
                Text(localizer.text("onboarding.approve"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button(localizer.text("agent.opensettings")) { installer.openSettings() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(localizer.text("onboarding.install"), action: onInstall)
                    .buttonStyle(.borderedProminent)
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
