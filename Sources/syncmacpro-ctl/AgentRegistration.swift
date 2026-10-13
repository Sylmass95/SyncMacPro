import Foundation
import ServiceManagement
import SyncKit

/// Enregistrement de l'agent auprès de macOS. `SMAppService` n'agit que sur le bundle de l'appelant :
/// l'outil doit donc être lancé depuis `SyncMacPro.app/Contents/MacOS/` (voir scripts/make-dev-bundle.sh).
enum AgentRegistration {
    static let plistName = "\(AgentIdentifiers.launchdLabel).plist"

    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    private static func requireBundle() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw RegistrationError.notInBundle
        }
    }

    enum RegistrationError: Error, LocalizedError {
        case notInBundle

        var errorDescription: String? {
            "L'enregistrement de l'agent exige de lancer l'outil depuis l'app : "
                + "~/Applications/SyncMacPro.app/Contents/MacOS/syncmacpro-ctl (voir scripts/make-dev-bundle.sh)."
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "installé et actif"
        case .requiresApproval:
            return "installé, mais à autoriser dans Réglages Système › Général › Éléments de connexion et extensions"
        case .notRegistered: return "non installé"
        case .notFound: return "introuvable dans le bundle (le plist de l'agent manque)"
        @unknown default: return "état inconnu"
        }
    }

    static func status() throws -> String {
        try requireBundle()
        return describe(service.status)
    }

    static func install() throws -> String {
        try requireBundle()
        if service.status != .enabled { try service.register() }
        let status = service.status
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return describe(status)
    }

    static func uninstall() throws -> String {
        try requireBundle()
        try service.unregister()
        return describe(service.status)
    }
}
