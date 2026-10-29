import Foundation
import Observation
import SyncKit

public enum WizardStep: Equatable, Sendable {
    case service, prepare, name, connect, test, done
}

/// L'assistant de connexion, sans vue : étapes, saisies, dialogue avec rclone par l'agent.
@MainActor
@Observable
public final class WizardModel {
    public var step: WizardStep = .service
    public private(set) var service: CloudService = .drive
    public var ownClient = true
    public var clientID = ""
    public var clientSecret = ""
    public var s3Provider: S3Provider = .aws
    public var accessKey = ""
    public var secretKey = ""
    public var region = ""
    public var endpoint = ""
    /// 1.8.10 : NAS par connexion SMB directe.
    public var smbHost = ""
    public var smbUser = ""
    public var smbPassword = ""
    public var name = ""
    public private(set) var question: RemoteQuestion?
    public var answer = ""
    public private(set) var busy = false
    public private(set) var waitingForBrowser = false
    public private(set) var error: String?
    public private(set) var testResult: RemoteTestResult?
    public private(set) var reconnecting = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored let model: AgentModel
    @ObservationIgnored let localizer: Localizer

    public init(model: AgentModel, localizer: Localizer = .system) {
        self.model = model
        self.localizer = localizer
    }

    /// Reconnexion d'une connexion existante : on va droit au navigateur.
    public init(reconnecting remote: RemoteInfo, model: AgentModel, localizer: Localizer = .system) {
        self.model = model
        self.localizer = localizer
        service = CloudService.forType(remote.type) ?? .drive
        name = remote.name
        reconnecting = true
        step = .connect
    }

    public var nameProblem: RemoteNameProblem? {
        RemoteNameRule.problem(name, existing: model.remotes.map(\.name))
    }

    public var canContinue: Bool {
        switch step {
        case .service: return true
        case .prepare:
            switch service {
            case .drive: return !ownClient || (!clientID.trimmed.isEmpty && !clientSecret.trimmed.isEmpty)
            case .s3:
                return !accessKey.trimmed.isEmpty && !secretKey.trimmed.isEmpty
                    && (!s3Provider.needsEndpoint || !endpoint.trimmed.isEmpty)
            case .smb: return !smbHost.trimmed.isEmpty && !smbUser.trimmed.isEmpty && !smbPassword.isEmpty
            case .dropbox, .onedrive: return true
            }
        case .name: return nameProblem == nil
        case .connect:
            guard let question else { return !busy }
            return !question.required || !answer.trimmed.isEmpty
        case .test, .done: return true
        }
    }

    /// Paramètres connus d'avance, passés à `rclone config create`.
    public var parameters: [String: String] {
        switch service {
        case .drive:
            var values = ["scope": "drive"]
            if ownClient {
                values["client_id"] = clientID.trimmed
                values["client_secret"] = clientSecret.trimmed
            }
            return values
        case .s3:
            var values = [
                "provider": s3Provider.rawValue, "env_auth": "false",
                "access_key_id": accessKey.trimmed, "secret_access_key": secretKey.trimmed,
            ]
            if !region.trimmed.isEmpty { values["region"] = region.trimmed }
            if s3Provider.needsEndpoint { values["endpoint"] = endpoint.trimmed }
            return values
        case .smb: return ["host": smbHost.trimmed, "user": smbUser.trimmed, "pass": smbPassword]
        case .dropbox, .onedrive: return [:]
        }
    }

    public func choose(_ chosen: CloudService) {
        service = chosen
        name = RemoteNameRule.suggestion(localizer.text(chosen.nameKey), existing: model.remotes.map(\.name))
        // Le NAS des tâches : son adresse et le compte du partage sont déjà connus.
        if chosen == .smb, let share = model.tasks.values.sorted(by: { $0.name < $1.name })
            .lazy.compactMap({ SMBShare.of($0.source) ?? SMBShare.of($0.destination) }).first {
            if smbHost.isEmpty { smbHost = share.host }
            if smbUser.isEmpty { smbUser = share.user ?? "" }
        }
        step = .prepare
    }

    public func next() {
        guard canContinue else { return }
        switch step {
        case .service: step = .prepare
        case .prepare: step = .name
        case .name: step = .connect
        case .connect, .test, .done: break
        }
    }

    public func back() {
        error = nil
        switch step {
        case .prepare: step = .service
        case .name: step = .prepare
        case .connect where question == nil && !busy && !reconnecting: step = .name
        default: break
        }
    }

    /// Crée la connexion (ou la reconnecte), puis répond seul aux questions connues.
    public func connect() async {
        let first: RemoteConfigStep = reconnecting
            ? .reconnect(name: name)
            : .start(name: name, type: service.rcloneType, parameters: parameters)
        await run(first)
    }

    public func submitAnswer() async {
        guard let question, canContinue else { return }
        self.question = nil
        await run(.answer(name: name, state: question.state, result: answer.trimmed))
    }

    private func run(_ first: RemoteConfigStep) async {
        error = nil
        cancelled = false
        busy = true
        defer {
            busy = false
            waitingForBrowser = false
        }
        var result = await model.configureRemote(first)
        var automaticAnswers = 0
        while true {
            if cancelled { return }
            switch result {
            case .failed(let message):
                error = message
                return
            case .done:
                step = .test
                await retest()
                return
            case .question(let next):
                guard let automatic = CloudService.autoAnswer(option: next.option) else {
                    question = next
                    answer = next.defaultValue
                    if let refusal = next.error { error = refusal }   // rclone a refusé la réponse précédente
                    return
                }
                automaticAnswers += 1
                guard automaticAnswers <= 20 else {
                    // rclone repose sans cesse une question à réponse automatique : on s'arrête au lieu de boucler.
                    error = localizer.text("wizard.error.loop")
                    await model.cancelRemoteConfiguration(name)
                    return
                }
                waitingForBrowser = next.option == "config_is_local" && automatic == "true"
                result = await model.configureRemote(.answer(name: name, state: next.state, result: automatic))
                waitingForBrowser = false
            }
        }
    }

    public func cancel() async {
        cancelled = true
        question = nil
        await model.cancelRemoteConfiguration(name)
    }

    public func retest() async {
        testResult = nil
        let result = await model.testRemote(name)
        testResult = result
        if result.ok { step = .done }
    }

    /// Le test a échoué : on supprime la connexion et on revient corriger les saisies.
    public func fix() async {
        testResult = nil
        // Une reconnexion porte sur une connexion existante : on ne la supprime pas, on réessaie.
        if reconnecting {
            step = .connect
            return
        }
        if let refusal = await model.deleteRemote(name) {
            error = refusal   // la connexion n'a pas pu être supprimée : on reste sur le test
            return
        }
        step = .prepare
    }

    public func keepAnyway() {
        step = .done
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
