import Foundation
import XCTest
@testable import SyncKit

final class FakeClock: SchedulerClock, @unchecked Sendable {
    private let current: Locked<Date>
    let calendar: Calendar

    init(_ start: Date, calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()) {
        current = Locked(start)
        self.calendar = calendar
    }

    func now() -> Date { current.get() }
    func set(_ date: Date) { current.set(date) }
    func advance(_ seconds: TimeInterval) { current.set(current.get().addingTimeInterval(seconds)) }
}

final class FakeConditions: SystemConditions, @unchecked Sendable {
    let acPower = Locked(true)
    let network = Locked(true)
    let reachable = Locked(true)

    func isOnACPower() -> Bool { acPower.get() }
    func isNetworkAvailable() -> Bool { network.get() }
    func isReachable(_ endpoint: Endpoint) -> Bool { reachable.get() }
}

final class FakeNotifier: AgentNotifier, @unchecked Sendable {
    let messages = Locked<[(title: String, body: String)]>([])
    func notify(title: String, body: String) { messages.set(messages.get() + [(title, body)]) }
}

final class FakeActivity: ActivityHolding, @unchecked Sendable {
    let begins = Locked(0)
    let ends = Locked(0)
    func begin() { begins.set(begins.get() + 1) }
    func end() { ends.set(ends.get() + 1) }
}

/// Porte que le test ouvre quand il veut qu'une exécution se termine.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
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

final class FakeRunner: TaskRunning, @unchecked Sendable {
    let calls = Locked<[String]>([])
    let ranTasks = Locked<[SyncTask]>([])
    let status = Locked<RunStatus>(.succeeded)
    let retryable = Locked(true)
    let message = Locked<String?>(nil)
    let failure = Locked<Error?>(nil)
    let snapshot = Locked<TransferSnapshot?>(nil)
    let dryRuns = Locked<[Bool]>([])
    let lines = Locked<[String]>([])
    private let gate: Gate?
    private let stopped = Locked(false)

    init(status: RunStatus = .succeeded, gated: Bool = false) {
        self.status.set(status)
        gate = gated ? Gate() : nil
    }

    func release() { gate?.release() }

    func run(
        _ task: SyncTask, dryRun: Bool, onUpdate: @escaping @Sendable (RunUpdate) -> Void
    ) async throws -> RunResult {
        calls.set(calls.get() + ["run"])
        dryRuns.set(dryRuns.get() + [dryRun])
        ranTasks.set(ranTasks.get() + [task])
        onUpdate(.phase(.running))
        if let current = snapshot.get() { onUpdate(.snapshot(current)) }
        for line in lines.get() { onUpdate(.line(line)) }
        if let gate { await gate.wait() }
        if let failure = failure.get() { throw failure }
        let final = stopped.get() ? RunStatus.stopped : status.get()
        return RunResult(
            status: final, engine: .rsync,
            summary: RunSummary(filesTransferred: 1, message: message.get()), snapshot: TransferSnapshot(),
            retryable: retryable.get()
        )
    }

    func pause() { calls.set(calls.get() + ["pause"]) }
    func resume() { calls.set(calls.get() + ["resume"]) }
    func stop() {
        calls.set(calls.get() + ["stop"])
        stopped.set(true)
        gate?.release()
    }
}

/// Fabrique de faux exécuteurs : un par exécution, tous conservés pour que le test les pilote.
final class RunnerFactory: @unchecked Sendable {
    let runners = Locked<[FakeRunner]>([])
    let status = Locked<RunStatus>(.succeeded)
    let retryable = Locked(true)
    let failure = Locked<Error?>(nil)
    let snapshot = Locked<TransferSnapshot?>(nil)
    let lines = Locked<[String]>([])
    let gated: Bool

    init(gated: Bool = false) { self.gated = gated }

    func make() -> TaskRunning {
        let runner = FakeRunner(status: status.get(), gated: gated)
        runner.failure.set(failure.get())
        runner.retryable.set(retryable.get())
        runner.snapshot.set(snapshot.get())
        runner.lines.set(lines.get())
        runners.set(runners.get() + [runner])
        return runner
    }

    /// Exécutions réellement lancées (`run` appelé) : asynchrone, à n'utiliser qu'après `waitForIdle`.
    var runCount: Int { runners.get().reduce(0) { $0 + $1.ranTasks.get().count } }
    /// Exécuteurs créés : synchrone avec le démarrage d'une tâche, sûr à lire juste après `tick()`.
    var created: Int { runners.get().count }
}

/// Attend qu'une condition devienne vraie (2 s au plus) ; faux si elle ne l'est jamais.
func eventually(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

final class FakeRemotes: RemoteConfiguring, @unchecked Sendable {
    let remotes = Locked<[RemoteInfo]>([])
    let steps = Locked<[RemoteConfigStep]>([])
    let deleted = Locked<[String]>([])
    let cancelled = Locked<[String]>([])
    let outcomes = Locked<[Result<RemoteConfigOutcome, RemoteConfigError>]>([])
    let gate = Locked<TestGate?>(nil)
    /// Si défini, `listRemotes` attend cette porte (appel lent).
    let listGate = Locked<TestGate?>(nil)
    let idleWaits = Locked(0)

    func listRemotes() async throws -> [RemoteInfo] {
        if let gate = listGate.get() { await gate.wait() }
        return remotes.get()
    }
    func waitForIdle() async { idleWaits.set(idleWaits.get() + 1) }
    func configure(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        steps.set(steps.get() + [step])
        if case .start(let name, let type, _) = step { remotes.set(remotes.get() + [RemoteInfo(name: name, type: type)]) }
        if let gate = gate.get() { await gate.wait() }
        var queue = outcomes.get()
        let next = queue.isEmpty ? .success(.done) : queue.removeFirst()
        outcomes.set(queue)
        return try next.get()
    }
    func cancelConfiguration(_ name: String) {
        cancelled.set(cancelled.get() + [name])
        gate.get()?.release()
    }
    func cancelAll() { cancelled.set(cancelled.get() + ["*"]); gate.get()?.release() }
    func forgetCancellation(_ name: String) {}
    func delete(_ name: String) async throws {
        deleted.set(deleted.get() + [name])
        remotes.set(remotes.get().filter { $0.name != name })
    }
    func test(_ name: String) async -> RemoteTestResult { RemoteTestResult(ok: remotes.get().contains { $0.name == name }) }
    func folders(remote: String, path: String) async throws -> [String] { ["A", "B"] }
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
