import Foundation
import SyncKit
@testable import SyncMacProUI

/// Agent scripté : les réponses de `status()` sont consommées dans l'ordre, la dernière se répète.
final class FakeAgent: AgentConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var statusResults: [Result<AgentStatus, Error>] = []
    private var _tasks: [SyncTask] = []
    private var _history: Result<[RunRecord], Error> = .success([])
    private var _performError: Error?
    private var _watchError: Error?
    private var _statusCalls = 0
    private var _historyCalls = 0
    private var _watchStarts = 0
    private var _watchCancels = 0
    private var _performed: [AgentRequest] = []
    private var _holdNextStatus: TestGate?
    private var onEvent: (@Sendable (AgentEvent) -> Void)?
    private var onEnd: (@Sendable () -> Void)?

    // MARK: réglages

    func setStatus(_ results: Result<AgentStatus, Error>...) { locked { statusResults = results } }
    func setTasks(_ tasks: [SyncTask]) { locked { _tasks = tasks } }
    func setHistory(_ result: Result<[RunRecord], Error>) { locked { _history = result } }
    func setPerformError(_ error: Error?) { locked { _performError = error } }
    func setWatchError(_ error: Error?) { locked { _watchError = error } }

    // MARK: observation

    var statusCalls: Int { locked { _statusCalls } }
    var historyCalls: Int { locked { _historyCalls } }
    var watchStarts: Int { locked { _watchStarts } }
    var watchCancels: Int { locked { _watchCancels } }
    var performed: [AgentRequest] { locked { _performed } }

    func emit(_ event: AgentEvent) { locked { onEvent }?(event) }
    func endWatch() { locked { onEnd }?() }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: AgentConnecting

    func status() async throws -> AgentStatus {
        let (result, hold): (Result<AgentStatus, Error>, TestGate?) = locked {
            _statusCalls += 1
            let held = _holdNextStatus
            _holdNextStatus = nil
            if statusResults.count > 1 { return (statusResults.removeFirst(), held) }
            return (statusResults.first ?? .failure(AgentClientError.unreachable), held)
        }
        // La réponse est choisie à l'appel ; elle n'arrive qu'une fois la porte ouverte (appel XPC lent).
        if let hold { await hold.wait() }
        return try result.get()
    }

    /// Le prochain appel à `status()` restera en suspens jusqu'à `gate.release()`.
    func holdNextStatus(_ gate: TestGate) { locked { _holdNextStatus = gate } }

    func listTasks() async throws -> [SyncTask] { locked { _tasks } }

    func history(taskID: UUID?, limit: Int) async throws -> [RunRecord] {
        let result = locked { () -> Result<[RunRecord], Error> in
            _historyCalls += 1
            return _history
        }
        return try result.get()
    }

    func perform(_ request: AgentRequest) async throws {
        let error: Error? = locked {
            _performed.append(request)
            return _performError
        }
        if let error { throw error }
    }

    func startWatching(
        onEvent: @escaping @Sendable (AgentEvent) -> Void, onEnd: @escaping @Sendable () -> Void
    ) async throws -> any AgentWatching {
        let error: Error? = locked {
            _watchStarts += 1
            if _watchError == nil {
                self.onEvent = onEvent
                self.onEnd = onEnd
            }
            return _watchError
        }
        if let error { throw error }
        return FakeWatch(owner: self)
    }

    fileprivate func watchWasCancelled() { locked { _watchCancels += 1 } }
}

final class FakeWatch: AgentWatching, @unchecked Sendable {
    private let owner: FakeAgent
    init(owner: FakeAgent) { self.owner = owner }
    func cancel() { owner.watchWasCancelled() }
}

/// Sommeil piloté par le test : chaque `sleep` attend qu'on le libère, et reste annulable.
final class ManualSleeper: Sleeping, @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var nextID = 0
    private var _requests: [TimeInterval] = []

    /// Durées demandées, dans l'ordre.
    var requests: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func sleep(seconds: TimeInterval) async throws {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            nextID += 1
            _requests.append(seconds)
            return nextID
        }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, seconds: seconds, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let cancelled = waiters.first { $0.id == id }
            waiters.removeAll { $0.id == id }
            lock.unlock()
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Libère les sommeils d'une durée donnée.
    func release(seconds: TimeInterval) {
        lock.lock()
        let due = waiters.filter { $0.seconds == seconds }
        waiters.removeAll { $0.seconds == seconds }
        lock.unlock()
        due.forEach { $0.continuation.resume() }
    }

    func releaseAll() {
        lock.lock()
        let all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.continuation.resume() }
    }
}

func makeStatus(
    paused: Bool = false, recovered: Bool = false, _ tasks: [AgentTaskInfo] = []
) -> AgentStatus {
    AgentStatus(globalPause: paused, stateRecovered: recovered, taskLoadError: nil, tasks: tasks)
}

/// Porte ouverte par le test : tout ce qui attend reprend d'un coup.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
