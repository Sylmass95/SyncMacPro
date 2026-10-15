import AppKit
import Sparkle

/// Sparkle sans aucune fenêtre : les mises à jour trouvées sont téléchargées, puis installées quand l'app le décide
/// (`installNow`, agent au repos). Erreurs et états remontent à `UpdateModel`.
/// Si l'app est quittée (⌘Q, fermeture de session) avec une mise à jour prête, Sparkle l'installe à la fermeture : c'est
/// voulu (spec) ; l'agent, lui, n'est redémarré qu'au repos (`AgentInstaller.reRegisterAfterUpdate`).
@MainActor
public final class SparkleUpdateDriver: UpdateDriving {
    public var onEvent: ((UpdateEvent) -> Void)?
    public var automaticallyChecks = true {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private let bundle: Bundle
    private var updater: SPUUpdater?
    private var userDriver: SilentUserDriver?
    private var foundVersion: String?
    private var pendingInstall: ((SPUUserUpdateChoice) -> Void)?

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Seulement pour l'app installée (bundle `.app` dont l'Info.plist déclare le flux) ; `nil` en développement.
    public static func makeIfBundled(bundle: Bundle = .main) -> SparkleUpdateDriver? {
        guard bundle.bundleURL.pathExtension == "app", bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SparkleUpdateDriver(bundle: bundle)
    }

    public func start() {
        guard updater == nil else { return }
        let userDriver = SilentUserDriver(owner: self)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: nil)
        updater.automaticallyChecksForUpdates = automaticallyChecks
        // Le téléchargement est décidé ici (`updateFound`), l'installation par l'app (`installNow`).
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
            self.updater = updater
            self.userDriver = userDriver
        } catch {
            failed(error.localizedDescription)
        }
    }

    public func checkNow() { updater?.checkForUpdates() }

    public func installNow() {
        guard let reply = pendingInstall else { return }
        pendingInstall = nil
        onEvent?(.installing)
        reply(.install)
    }

    // MARK: réponses aux demandes de Sparkle (fil principal)

    func checking() { onEvent?(.checking) }
    func notFound() { onEvent?(.upToDate) }
    func failed(_ message: String) {
        pendingInstall = nil
        onEvent?(.failed(message))
    }

    /// `resuming` : Sparkle reprend une installation déjà commencée ; elle attend, elle aussi, la décision de l'app.
    func updateFound(version: String, resuming: Bool = false, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundVersion = version
        if resuming {
            readyToInstall(reply: reply)
            return
        }
        onEvent?(.downloading(version))
        reply(.install)
    }

    func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingInstall = reply
        onEvent?(.ready(foundVersion ?? ""))
    }

    func installing() { onEvent?(.installing) }

    func permissionResponse() -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyChecks, sendSystemProfile: false)
    }
}

/// Le pilote utilisateur de Sparkle (protocole Objective-C, appelé sur le fil principal) : il transmet au pilote.
final class SilentUserDriver: NSObject, SPUUserDriver {
    private weak var owner: SparkleUpdateDriver?

    @MainActor init(owner: SparkleUpdateDriver) {
        self.owner = owner
    }

    private func onMain(_ body: @MainActor (SparkleUpdateDriver) -> Void) {
        MainActor.assumeIsolated {
            if let owner { body(owner) }
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        var response = SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)
        onMain { response = $0.permissionResponse() }
        reply(response)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { onMain { $0.checking() } }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let resuming = state.stage == .installing
        onMain { $0.updateFound(version: version, resuming: resuming, reply: reply) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onMain { $0.notFound() }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let message = error.localizedDescription
        onMain { $0.failed(message) }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onMain { $0.readyToInstall(reply: reply) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        onMain { $0.installing() }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
