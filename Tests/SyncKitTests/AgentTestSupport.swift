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
    let message = Locked<String?>(nil)
    let failure = Locked<Error?>(nil)
    let snapshot = Locked<TransferSnapshot?>(nil)
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
        ranTasks.set(ranTasks.get() + [task])
        onUpdate(.phase(.running))
        if let current = snapshot.get() { onUpdate(.snapshot(current)) }
        if let gate { await gate.wait() }
        if let failure = failure.get() { throw failure }
        let final = stopped.get() ? RunStatus.stopped : status.get()
        return RunResult(
            status: final, engine: .rsync,
            summary: RunSummary(filesTransferred: 1, message: message.get()), snapshot: TransferSnapshot()
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
    let failure = Locked<Error?>(nil)
    let snapshot = Locked<TransferSnapshot?>(nil)
    let gated: Bool

    init(gated: Bool = false) { self.gated = gated }

    func make() -> TaskRunning {
        let runner = FakeRunner(status: status.get(), gated: gated)
        runner.failure.set(failure.get())
        runner.snapshot.set(snapshot.get())
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
