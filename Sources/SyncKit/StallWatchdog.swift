import Darwin
import Foundation

/// Repère un moteur figé : ni sortie ni temps de calcul pendant `timeout` secondes, pauses exclues.
///
/// rsync n'a pas de `--timeout` (une pause le ferait échouer, voir `RsyncCommandBuilder`). Face à un NAS ou un disque
/// qui ne répond plus, il attend dans le noyau sans fin : l'exécution resterait « en cours » pour toujours et
/// bloquerait les suivantes. Un rsync qui travaille sans rien écrire (empreintes d'un gros fichier) consomme du
/// temps de calcul : il n'est pas considéré comme figé.
///
/// Le temps est mesuré avec l'horloge de démarrage du système (`systemUptime`), qui s'arrête pendant la veille :
/// un Mac qui dort ne fait pas passer une copie pour figée à son réveil.
final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity: TimeInterval
    private var lastCPU: UInt64?
    private var task: Task<Void, Never>?
    private var fired = false

    private let timeout: TimeInterval
    private let interval: TimeInterval
    private let isPaused: @Sendable () -> Bool
    private let cpuTime: @Sendable () -> UInt64?
    private let onStall: @Sendable () -> Void

    init(
        timeout: TimeInterval, interval: TimeInterval,
        isPaused: @escaping @Sendable () -> Bool,
        cpuTime: @escaping @Sendable () -> UInt64?,
        onStall: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.interval = interval
        self.isPaused = isPaused
        self.cpuTime = cpuTime
        self.onStall = onStall
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    /// Le moteur a écrit quelque chose.
    func noteActivity() {
        lock.lock(); lastActivity = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    var hasFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }

    func start() {
        guard timeout > 0 else { return }
        let nanoseconds = UInt64(max(0.01, interval) * 1_000_000_000)
        task = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled || check() { return }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Vrai si le moteur vient d'être déclaré figé.
    private func check() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = cpuTime()
        lock.lock()
        if isPaused() || (cpu != nil && cpu != lastCPU) { lastActivity = now }
        lastCPU = cpu
        let stalled = !fired && now - lastActivity >= timeout
        if stalled { fired = true }
        lock.unlock()
        if stalled { onStall() }
        return stalled
    }
}

extension RunningProcess {
    /// Temps de calcul cumulé (utilisateur + système) des processus de son groupe : rsync en lance trois.
    func groupCPUTime() -> UInt64? {
        let capacity = 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        var total: UInt64 = 0
        var found = false
        for member in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where member > 0 {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(member, RUSAGE_INFO_V2, $0) }
            }
            if status == 0 {
                total &+= info.ri_user_time &+ info.ri_system_time
                found = true
            }
        }
        return found ? total : nil
    }
}
