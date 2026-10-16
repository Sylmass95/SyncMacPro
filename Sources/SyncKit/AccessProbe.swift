import Foundation

/// Lister un dossier dans un délai : fait apparaître la demande d'autorisation de macOS pour un dossier protégé, et
/// dit s'il a répondu (1.6.2, 1.6.4).
public enum AccessProbe {
    /// Vrai si le programme a fini dans le délai (le dossier a répondu, même par une erreur).
    public static func answers(executable: String, arguments: [String], timeout: TimeInterval) async -> Bool {
        guard let process = try? ProcessRunner.spawn(executable: executable, arguments: arguments, onLine: { _ in }) else { return true }
        let timedOut = Locked(false)
        let delay = UInt64(max(0, timeout) * 1_000_000_000)
        let timer = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            timedOut.set(true)
            process.terminate(killAfter: 2)
        }
        _ = await process.waitForExit()
        timer.cancel()
        return !timedOut.get()
    }

    /// Après une mise à jour : chaque dossier est listé, l'un après l'autre, en laissant le temps de répondre à la
    /// demande de macOS (5 min chacun au plus).
    public static let touchAll: @Sendable ([String]) async -> Void = { folders in
        for folder in folders { _ = await answers(executable: "/bin/ls", arguments: ["-f", folder], timeout: 300) }
    }
}
