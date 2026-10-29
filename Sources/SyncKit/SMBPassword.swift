import CommonCrypto
import Foundation
import Security

/// 1.8.12 : le mot de passe d'un partage SMB, tel que macOS le garde dans le trousseau pour le monter (Finder, montage
/// automatique). La première lecture par l'agent, macOS demande l'autorisation (« Toujours autoriser ») ; refusée, ou
/// sans mot de passe enregistré : `nil`, et rien ne change.
public enum KeychainSMBPassword {
    public static func lookup(_ share: SMBShare) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: share.host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let user = share.user { query[kSecAttrAccount as String] = user }
        for withProtocol in [true, false] {
            var attempt = query
            if withProtocol { attempt[kSecAttrProtocol as String] = kSecAttrProtocolSMB }
            var item: CFTypeRef?
            if SecItemCopyMatching(attempt as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
               let password = String(data: data, encoding: .utf8), !password.isEmpty {
                return password
            }
        }
        return nil
    }
}

/// Un mot de passe sous la forme qu'attend rclone (`rclone obscure`) : AES-256-CTR avec la clé publique de rclone, vecteur
/// aléatoire en tête, le tout en base64 « URL » sans remplissage. Pas un secret : rclone ne veut juste pas de texte clair.
public enum RcloneObscure {
    private static let key: [UInt8] = [
        0x9c, 0x93, 0x5b, 0x48, 0x73, 0x0a, 0x55, 0x4d, 0x6b, 0xfd, 0x7c, 0x63, 0xc8, 0x86, 0xa9, 0x2b,
        0xd3, 0x90, 0x19, 0x8e, 0xb8, 0x12, 0x8a, 0xfb, 0xf4, 0xde, 0x16, 0x2b, 0x8b, 0x95, 0xf6, 0x38,
    ]

    public static func obscure(_ plain: String) -> String {
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        _ = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        let input = Array(plain.utf8)
        var output = [UInt8](repeating: 0, count: input.count)
        var cryptor: CCCryptorRef?
        CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                iv, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        var moved = 0
        CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        CCCryptorRelease(cryptor)
        return Data(iv + output).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension SMBShare {
    /// Connexion rclone écrite dans le chemin, sans fichier de configuration (`:smb,host=…,user=…:partage/dossier`) ; le mot
    /// de passe passe par `RCLONE_SMB_PASS`.
    public var inlineSpec: String {
        func value(_ text: String) -> String {
            text.contains(where: { ",:'\"=".contains($0) }) ? "'" + text.replacingOccurrences(of: "'", with: "''") + "'" : text
        }
        var spec = ":smb,host=\(value(host))"
        if let user { spec += ",user=\(value(user))" }
        return spec + ":" + (subpath.isEmpty ? share : "\(share)/\(subpath)")
    }
}

/// Mot de passe du trousseau pour l'agent : la réponse est retenue (macOS ne redemande pas à chaque copie), un refus
/// quelques heures ; une question restée sans réponse (la nuit) ne bloque pas la copie au-delà de `timeout`.
public final class CachedSMBPassword: @unchecked Sendable {
    public static let refusalMemory: TimeInterval = 6 * 3600
    private let lookup: @Sendable (SMBShare) -> String?
    private let timeout: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var found: [String: String] = [:]
    private var refusedAt: [String: Date] = [:]

    public init(timeout: TimeInterval = 120, lookup: @escaping @Sendable (SMBShare) -> String? = KeychainSMBPassword.lookup,
                now: @escaping () -> Date = { Date() }) {
        self.lookup = lookup
        self.timeout = timeout
        self.now = now
    }

    public func password(for share: SMBShare) -> String? {
        let key = "\(share.user ?? "")@\(share.host.lowercased())"
        lock.lock()
        if let password = found[key] { lock.unlock(); return password }
        if let refused = refusedAt[key], now().timeIntervalSince(refused) < Self.refusalMemory { lock.unlock(); return nil }
        lock.unlock()
        let answer = Locked<String??>(nil)
        let done = DispatchSemaphore(value: 0)
        let lookup = self.lookup
        DispatchQueue.global().async {
            answer.set(.some(lookup(share)))
            done.signal()
        }
        let password = done.wait(timeout: .now() + timeout) == .success ? (answer.get() ?? nil) : nil
        lock.lock(); defer { lock.unlock() }
        if let password { found[key] = password } else { refusedAt[key] = now() }
        return password
    }
}
