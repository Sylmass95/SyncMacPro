import Darwin
import Foundation

public enum ProcessError: Error, Equatable {
    case spawnFailed(errno: Int32)
}

public struct ProcessOutputLine: Equatable, Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public let stream: Stream
    public let text: String
}

/// Un processus lancé dans son propre groupe : pause, reprise et arrêt touchent aussi ses sous-processus.
public final class RunningProcess: @unchecked Sendable {
    public let pid: pid_t
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(pid: pid_t) { self.pid = pid }

    /// Fige le processus (SIGSTOP) : il reprendra exactement où il en était.
    public func pause() { killpg(pid, SIGSTOP) }

    public func resume() { killpg(pid, SIGCONT) }

    /// Arrête proprement (SIGTERM). Un processus figé ne reçoit pas SIGTERM : on le reprend d'abord.
    /// Si le groupe n'est pas terminé après `grace` secondes (programme qui ignore SIGTERM, nettoyage bloqué),
    /// il est tué (SIGKILL) : sans cela, l'exécution et son verrou resteraient bloqués.
    public func terminate(killAfter grace: TimeInterval = 8) {
        killpg(pid, SIGCONT)
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, !self.hasExited else { return }
            killpg(self.pid, SIGKILL)
        }
    }

    private var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitCode != nil
    }

    /// Code de sortie ; 128 + n si le processus a été tué par le signal n.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Arrête un processus figé. S'il reste coincé dans le noyau (disque réseau qui ne répond plus, même SIGKILL
    /// n'agit qu'au retour du système de fichiers), on cesse de l'attendre au bout de `giveUpAfter` secondes : son
    /// exécution se termine en échec au lieu de rester bloquée pour toujours.
    public func terminateStalled(giveUpAfter: TimeInterval) {
        terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + giveUpAfter) { [weak self] in
            self?.finish(with: 128 + SIGKILL)
        }
    }

    func finish(with code: Int32) {
        lock.lock()
        guard exitCode == nil else { lock.unlock(); return }
        exitCode = code
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: code) }
    }
}

public enum ProcessRunner {
    /// Lance un programme et appelle `onLine` pour chaque ligne de sa sortie (découpée sur « \n » et « \r »).
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (ProcessOutputLine) -> Void
    ) throws -> RunningProcess {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw ProcessError.spawnFailed(errno: errno) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for descriptor in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, descriptor) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)   // entrée standard vide

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            // CLOEXEC_DEFAULT : l'enfant n'hérite d'aucun descripteur de l'appelant (en particulier pas les tubes d'un
            // autre lancement simultané, ce qui retarderait la fin de leur flux jusqu'à la fin de cet enfant).
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        posix_spawnattr_setpgroup(&attributes, 0)   // nouveau groupe dont l'identifiant est le pid
        // Le programme lancé hérite sinon du masque de signaux de ce thread, et pourrait ignorer SIGTERM.
        var noBlockedSignals = sigset_t()
        sigemptyset(&noBlockedSignals)
        posix_spawnattr_setsigmask(&attributes, &noBlockedSignals)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv = makeCStrings([executable] + arguments)
        let merged = (environment ?? ProcessInfo.processInfo.environment)
        let envp = makeCStrings(merged.map { "\($0.key)=\($0.value)" })
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessError.spawnFailed(errno: result)
        }

        let process = RunningProcess(pid: pid)
        let readers = DispatchGroup()
        for (descriptor, stream) in [(outPipe[0], ProcessOutputLine.Stream.stdout), (errPipe[0], .stderr)] {
            readers.enter()
            Thread.detachNewThread {
                read(descriptor: descriptor, stream: stream, onLine: onLine)
                close(descriptor)
                readers.leave()
            }
        }
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            readers.wait()                  // toute la sortie est livrée avant d'annoncer la fin
            process.finish(with: decode(status))
        }
        return process
    }

    private static func makeCStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) }
    }

    /// Code de sortie à partir de l'état renvoyé par `waitpid`.
    static func decode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func read(
        descriptor: Int32, stream: ProcessOutputLine.Stream, onLine: @Sendable (ProcessOutputLine) -> Void
    ) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)

        func emit(_ bytes: Data) {
            // Ce fil n'a pas de boucle d'événements : sans bassin local, les objets Foundation temporaires de chaque
            // ligne (expressions régulières, chemins) ne seraient libérés qu'à la fin du processus, soit des centaines
            // de Mo pour une copie d'un million de fichiers.
            autoreleasepool {
                let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { onLine(ProcessOutputLine(stream: stream, text: text)) }
            }
        }

        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(buffer, count: count)
            // Découpe au niveau des octets pour ne jamais couper un caractère UTF-8 en deux.
            while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                emit(pending[pending.startIndex..<index])
                pending = Data(pending[pending.index(after: index)...])
            }
        }
        emit(pending)
    }
}
