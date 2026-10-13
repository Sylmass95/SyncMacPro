import Foundation
import Security

public enum CodeSigning {
    /// Identifiant d'équipe de ce programme ; `nil` en signature ad hoc (pas de compte développeur).
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess, let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Exigence à imposer au client XPC : signé par la même équipe.
    public static func requirement(forTeam team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
