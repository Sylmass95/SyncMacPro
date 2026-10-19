import Foundation

/// Ordre de la liste (1.7.0) : enregistré par l'agent, c'est l'ordre de départ des exécutions en attente.
extension AgentCore {
    /// Les tâches disparues quittent l'ordre, les nouvelles arrivent à la fin.
    func syncOrder() {
        let known = Set(tasks.map(\.id))
        var order = state.order.filter { known.contains($0) }
        let placed = Set(order)
        order += tasks.map(\.id).filter { !placed.contains($0) }
        state.order = order
    }

    /// Nouvel ordre envoyé par l'app : les tâches connues dans l'ordre reçu, puis celles qu'il ne cite pas (ordre
    /// périmé : tâche créée entre-temps) dans leur ordre actuel. Les copies en cours ne sont pas touchées.
    public func reorder(_ ids: [UUID]) {
        let known = Set(state.order)
        var seen = Set<UUID>()
        var order = ids.filter { known.contains($0) && seen.insert($0).inserted }
        order += state.order.filter { !seen.contains($0) }
        state.order = order
        persist()
        emit(.stateChanged)
    }

    /// Place dans l'ordre de départ (0 = la première) : les copies ponctuelles avant toutes les tâches.
    func rank(of id: UUID) -> Int {
        if let index = oneOffOrder.firstIndex(of: id) { return index - oneOffOrder.count }
        return state.order.firstIndex(of: id) ?? Int.max
    }

    /// Ancienne file explicite (avant 1.7.0) : si elle tournait, ses éléments deviennent des demandes « Lancer » en
    /// tête de liste (l'élément en cours est repris par le rattrapage) ; sinon elle est oubliée.
    func migrateOldQueue() {
        if state.userQueueRunning {
            let front = (state.userQueueCurrent.map { [$0] } ?? []) + state.userQueue
            let known = Set(tasks.map(\.id))
            let kept = front.filter { known.contains($0) }
            state.order = kept + state.order.filter { !kept.contains($0) }
            for id in state.userQueue where known.contains(id) && !queue.contains(where: { $0.id == id }) {
                queue.append(QueuedRun(id: id, dueDate: .distantPast, manual: true))
            }
        }
        state.userQueue = []
        state.userQueueRunning = false
        state.userQueueCurrent = nil
    }
}
