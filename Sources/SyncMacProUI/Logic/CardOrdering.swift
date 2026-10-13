import Foundation
import SyncKit

/// En cours ou en pause, puis à valider, en attente (ou en file), puis par prochaine échéance ; désactivées en dernier.
public enum CardOrdering {
    private static func rank(_ state: TaskRunState) -> Int {
        switch state {
        case .running, .paused: return 0
        case .awaitingApproval: return 1
        case .waiting, .queued: return 2
        case .idle: return 3
        case .disabled: return 4
        }
    }

    public static func sorted(_ tasks: [AgentTaskInfo]) -> [AgentTaskInfo] {
        tasks.sorted { lhs, rhs in
            let (a, b) = (rank(lhs.state), rank(rhs.state))
            if a != b { return a < b }
            switch (lhs.nextDue, rhs.nextDue) {
            case (let x?, let y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
