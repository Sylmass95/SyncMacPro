import Foundation
import SyncKit

/// Test de connexion SSH de l'éditeur (1.8.1) : la clé est acceptée sans mot de passe, rsync est installé sur le NAS et
/// le dossier existe.
enum SSHProbe {
    enum Outcome: Equatable, Sendable {
        case ok, noRsync, noFolder, refused, other(Int32)

        init(code: Int32) {
            switch code {
            case 0: self = .ok
            case 3: self = .noRsync
            case 4: self = .noFolder
            case 255: self = .refused
            default: self = .other(code)
            }
        }
    }

    static func arguments(for access: SSHAccess) -> [String] {
        let quoted = "'" + access.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", access.target,
                "command -v rsync >/dev/null || exit 3; test -d \(quoted) || exit 4; exit 0"]
    }

    static func run(_ access: SSHAccess) async -> Outcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments(for: access)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: Outcome(code: $0.terminationStatus)) }
            do { try process.run() } catch { continuation.resume(returning: .refused) }
        }
    }
}
