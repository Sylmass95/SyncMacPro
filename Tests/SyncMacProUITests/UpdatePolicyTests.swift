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

    /// 1.6.7 : l'agent dont le programme a été remplacé ne lance plus rien ; la file lancée ne le garde pas occupé,
    /// seules les copies en cours (ou en pause) retardent son redémarrage.
    func testAnAgentWaitingForItsRestartIsIdleOnceItsCopiesAreDone() {
        var waiting = status([.waiting(reason: "mise à jour"), .idle], queue: QueueInfo(running: true, items: [UUID()], current: nil))
        waiting.restartPending = true
        XCTAssertTrue(UpdatePolicy.agentIsIdle(connected: true, status: waiting))
        var busy = status([.running])
        busy.restartPending = true
        XCTAssertFalse(UpdatePolicy.agentIsIdle(connected: true, status: busy))
        var paused = status([.paused])
        paused.restartPending = true
        XCTAssertFalse(UpdatePolicy.agentIsIdle(connected: true, status: paused))
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

extension UpdatePolicyTests {
    // 1.6.4 : avant de redémarrer l'agent mis à jour, les autorisations périmées sont effacées ; après, l'agent
    // redemande l'accès (macOS affiche ses demandes pendant que l'utilisateur est là).
    func testReRegistrationResetsPermissionsThenAsksAgain() async {
        let service = AgentUpdateTests.RecordingService(.enabled)
        let store = AgentUpdateTests().defaults()
        store.set("1.6.3 (209)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        var order: [String] = []
        await installer.reRegisterAfterUpdate(currentBuild: "1.6.4 (211)", defaults: store, pause: { _ in },
                                              beforeReRegistering: { order.append("reset") },
                                              afterReRegistering: { order.append("demande") })
        XCTAssertEqual(order, ["reset", "demande"])
        XCTAssertEqual(service.calls.first, "unregister")
    }

    func testPermissionResetCoversTheFolderServicesOnly() {
        var calls: [[String]] = []
        let failures = PermissionReset.resetAll(bundleID: "com.sylvain.syncmacpro") { arguments in calls.append(arguments); return 0 }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(Set(calls.map { $0[1] }), ["SystemPolicyNetworkVolumes", "SystemPolicyRemovableVolumes", "SystemPolicyDesktopFolder",
                                                  "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder"])
        XCTAssertTrue(calls.allSatisfy { $0.first == "reset" && $0.last == "com.sylvain.syncmacpro" })
        XCTAssertFalse(calls.contains { $0.contains("SystemPolicyAllFiles") }, "l'accès complet au disque ne se redemande pas : jamais effacé")
    }
}

extension UpdatePolicyTests {
    /// Revue 1.6.7 : l'agent à redémarrer après une mise à jour est périmé par définition ; seules ses copies en cours
    /// ou en pause retardent le redémarrage (un agent 1.6.6 ne dit pas `restartPending` et lançait sans arrêt).
    func testOnlyRunningCopiesDelayTheRestartOfAStaleAgent() {
        let queued = status([.queued, .waiting(reason: "x")], queue: QueueInfo(running: true, items: [UUID()], current: nil))
        XCTAssertEqual(UpdatePolicy.agentCanRestart(connection: .connected, status: queued), true)
        XCTAssertEqual(UpdatePolicy.agentCanRestart(connection: .connected, status: status([.running])), false)
        XCTAssertEqual(UpdatePolicy.agentCanRestart(connection: .connected, status: status([.paused])), false)
        XCTAssertNil(UpdatePolicy.agentCanRestart(connection: .connecting, status: nil))
        XCTAssertEqual(UpdatePolicy.agentCanRestart(connection: .unreachable, status: nil), true)
    }

    /// Revue 1.6.7 : un agent dont le programme a été remplacé est redémarré même si la version est déjà enregistrée
    /// (même version réinstallée, app déjà ouverte au moment du remplacement).
    func testAReplacedAgentIsRestartedEvenWithTheSameBuild() async {
        let service = AgentUpdateTests.RecordingService(.enabled)
        let store = AgentUpdateTests().defaults()
        store.set("1.6.7 (220)", forKey: AgentInstaller.registeredBuildKey)
        let installer = AgentInstaller(service: service)
        var order: [String] = []
        await installer.restartReplacedAgent(currentBuild: "1.6.7 (220)", defaults: store, pause: { _ in },
                                             beforeReRegistering: { order.append("reset") },
                                             afterReRegistering: { order.append("demande") })
        XCTAssertEqual(order, ["reset", "demande"])
        XCTAssertEqual(service.calls.first, "unregister")
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
