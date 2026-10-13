import Foundation
import SyncKit

/// Ce que montre l'icône de la barre de menus. Priorité : déconnecté > pause globale > copie en cours >
/// pause d'une tâche > erreur > repos (une erreur est donc masquée tant qu'une copie tourne).
public enum MenuBarState: Equatable, Sendable {
    case disconnected
    case idle
    case copying(percent: Int?, count: Int)
    case paused
    case error

    public static func make(
        connection: ConnectionState, status: AgentStatus?, progress: [UUID: ProgressInfo]
    ) -> MenuBarState {
        guard connection == .connected, let status else { return .disconnected }
        if status.globalPause { return .paused }
        let running = status.tasks.filter { $0.state == .running }
        if !running.isEmpty {
            let percent = running.count == 1 ? progress[running[0].id]?.overallPercent : nil
            return .copying(percent: percent, count: running.count)
        }
        if status.tasks.contains(where: { $0.state == .paused }) { return .paused }
        let failing: Set<RunStatus> = [.failed, .blocked, .quotaReached]
        let hasError = status.tasks.contains {
            $0.state == .awaitingApproval || ($0.lastRun.map { failing.contains($0.status) } ?? false)
        }
        return hasError ? .error : .idle
    }

    public var systemImage: String {
        switch self {
        case .disconnected: return "bolt.slash"
        case .idle, .copying: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    /// Texte à côté de l'icône : « 42 % » pour une copie, « 2 copies » pour plusieurs.
    public func title(_ localizer: Localizer) -> String? {
        guard case .copying(let percent, let count) = self else { return nil }
        if count == 1 { return percent.map { "\($0) %" } }
        return localizer.format("menubar.copies", count)
    }
}
