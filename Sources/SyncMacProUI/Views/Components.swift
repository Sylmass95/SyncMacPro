import SwiftUI
import SyncKit

struct StatePill: View {
    let state: TaskRunState
    let label: String

    private var tint: Color {
        switch state {
        case .running: return .blue
        case .paused: return .orange
        case .queued, .disabled: return .gray
        case .waiting: return .yellow
        case .awaitingApproval: return .red
        case .idle: return .green
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint == .yellow ? Color.primary : tint)
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    var message: String? = nil
    var spinner = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBanner: View {
    let connection: ConnectionState
    let installState: AgentInstallState
    let localizer: Localizer
    let onRetry: () -> Void
    let onInstall: () -> Void

    var body: some View {
        switch connection {
        case .connected:
            EmptyView()
        case .connecting:
            Banner(systemImage: "bolt", tint: .secondary, title: localizer.text("connection.connecting"), spinner: true) {}
        case .reconnecting(let attempt):
            Banner(
                systemImage: "bolt", tint: .orange,
                title: localizer.format("connection.reconnecting", attempt), spinner: true
            ) {}
        case .unreachable:
            Banner(
                systemImage: "bolt.slash", tint: .red, title: localizer.text("connection.unreachable.title"),
                message: localizer.text("connection.unreachable.body")
            ) {
                HStack {
                    if installState == .notRegistered {
                        Button(localizer.text("agent.install"), action: onInstall)
                    }
                    Button(localizer.text("connection.retry"), action: onRetry)
                }
            }
        case .versionMismatch(let agent):
            Banner(
                systemImage: "exclamationmark.triangle", tint: .red, title: localizer.text("connection.version.title"),
                message: localizer.format("connection.version.body", agent)
            ) {}
        }
    }
}
