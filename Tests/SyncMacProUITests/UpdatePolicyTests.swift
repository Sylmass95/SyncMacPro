import XCTest
import SyncKit
@testable import SyncMacProUI

/// Sous-projet 8 : quand installer une mise à jour, quand réinscrire l'agent, quand l'annoncer.
@MainActor
final class UpdatePolicyTests: XCTestCase {
    func status(_ states: [TaskRunState], queue: QueueInfo? = nil) -> AgentStatus {
        AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil,
                    tasks: states.map { AgentTaskInfo(id: UUID(), name: "t", state: $0) }, queue: queue)
    }

    func testAgentIdleness() {
        XCTAssertTrue(UpdatePolicy.agentIsIdle(connected: true, status: status([.idle, .waiting(reason: "x"), .disabled, .awaitingApproval])))
        XCTAssertFalse(UpdatePolicy.agentIsIdle(connected: true, status: status([.idle, .running])))
        XCTAssertFalse(UpdatePolicy.agentIsIdle(connected: true, status: status([.paused])))
        XCTAssertFalse(UpdatePolicy.agentIsIdle(connected: true, status: status([.queued])))
        XCTAssertFalse(UpdatePolicy.agentIsIdle(connected: true, status: status([], queue: QueueInfo(running: true, items: [UUID()], current: nil))),
                       "file lancée : l'élément suivant va partir")
        XCTAssertTrue(UpdatePolicy.agentIsIdle(connected: true, status: status([], queue: QueueInfo(running: false, items: [UUID()], current: nil))))
        XCTAssertTrue(UpdatePolicy.agentIsIdle(connected: false, status: nil), "agent injoignable : rien à couper, l'installation ne reste pas bloquée")
        XCTAssertTrue(UpdatePolicy.agentIsIdle(connected: true, status: nil))
    }

    func testInstallDecision() {
        XCTAssertTrue(UpdatePolicy.shouldInstall(ready: true, autoInstall: true, idle: true))
        XCTAssertFalse(UpdatePolicy.shouldInstall(ready: true, autoInstall: true, idle: false))
        XCTAssertFalse(UpdatePolicy.shouldInstall(ready: true, autoInstall: false, idle: true))
        XCTAssertFalse(UpdatePolicy.shouldInstall(ready: false, autoInstall: true, idle: true))
    }

    func testUpdatedAnnouncement() {
        XCTAssertTrue(UpdatePolicy.shouldNotifyUpdated(previous: "1.5.0 (189)", current: "1.6.0 (200)"))
        XCTAssertFalse(UpdatePolicy.shouldNotifyUpdated(previous: nil, current: "1.6.0 (200)"), "première installation : rien à annoncer")
        XCTAssertFalse(UpdatePolicy.shouldNotifyUpdated(previous: "1.6.0 (200)", current: "1.6.0 (200)"))
        XCTAssertFalse(UpdatePolicy.shouldNotifyUpdated(previous: "1.6.0 (200)", current: "dev"))
        XCTAssertFalse(UpdatePolicy.shouldNotifyUpdated(previous: "1.7.0 (210)", current: "1.6.0 (200)"), "retour en arrière à la main")
    }

    // La réinscription redémarre l'agent : jamais pendant une copie.
    func testAgentReRegistrationWaitsForIdleness() async {
        let service = AgentUpdateTests.RecordingService(.enabled)
        let store = AgentUpdateTests().defaults()
        store.set("1.5.0 (189)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        let probe = IdleProbe(answers: [false, false, true])
        await installer.reRegisterAfterUpdate(currentBuild: "1.6.0 (200)", defaults: store, pause: { duration in
            if duration >= 30_000_000_000 { probe.notePause() }
        }, isIdle: { probe.next() })
        XCTAssertEqual(probe.pauses, 2, "deux attentes de 30 s : l'agent copiait")
        XCTAssertEqual(service.calls.first, "unregister")
        XCTAssertEqual(store.string(forKey: AgentInstaller.registeredBuildKey), "1.6.0 (200)")
    }
}

final class IdleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var pauses = 0
    init(answers: [Bool]) { self.answers = answers }
    func next() -> Bool { lock.withLock { answers.isEmpty ? true : answers.removeFirst() } }
    func notePause() { lock.withLock { pauses += 1 } }
}
