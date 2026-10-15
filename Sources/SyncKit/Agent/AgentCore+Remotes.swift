import Foundation

extension AgentCore {
    func configurator() throws -> RemoteConfiguring {
        guard let remotes else { throw AgentError.rcloneMissing }
        return remotes
    }

    static func agentError(_ error: Error) -> Error {
        if error is AgentError { return error }
        if let config = error as? RemoteConfigError { return AgentError.invalidRemote(config.errorDescription ?? "\(config)") }
        return AgentError.invalidRemote((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    public func listRemotes() async throws -> [RemoteInfo] {
        do { return try await configurator().listRemotes() } catch { throw Self.agentError(error) }
    }

    /// Une étape de configuration. Une création ratée ou annulée ne laisse rien dans la configuration de rclone.
    public func configureRemote(_ step: RemoteConfigStep) async throws -> RemoteConfigOutcome {
        let rclone = try configurator()
        let name = step.name
        try Self.check(step)
        guard !configuringRemotes.contains(name) else { throw AgentError.remoteBusy }
        // Réservé avant tout `await` : l'acteur est réentrant, une seconde demande du même nom serait sinon acceptée.
        configuringRemotes.insert(name)
        rclone.forgetCancellation(name)   // aucune annulation d'une étape précédente ne vaut pour celle-ci
        defer {
            configuringRemotes.remove(name)
            cancelledRemotes.remove(name)
            rclone.forgetCancellation(name)
        }
        switch step {
        case .start:
            let existing = try await listRemotes().map(\.name)
            if let problem = RemoteNameRule.problem(name, existing: existing) {
                throw AgentError.invalidRemote(Self.message(problem))
            }
            // Annulée pendant la lecture de la liste : on s'arrête avant de lancer rclone.
            if cancelledRemotes.contains(name) { throw AgentError.invalidRemote(RemoteConfigError.cancelled.errorDescription ?? "") }
            creatingRemotes.insert(name)
        case .reconnect:
            // Une connexion reconnectée existe : elle n'est jamais supprimée, même après une création inachevée.
            creatingRemotes.remove(name)
        case .answer:
            break
        }
        do {
            let outcome = try await rclone.configure(step)
            if outcome == .done {
                creatingRemotes.remove(name)
                await refreshRemoteTypes()   // une nouvelle connexion : son type compte pour les plafonds
            }
            return outcome
        } catch {
            if creatingRemotes.remove(name) != nil { try? await rclone.delete(name) }
            throw Self.agentError(error)
        }
    }

    public func cancelRemoteConfiguration(_ name: String) async {
        // Seulement si une étape est en cours : sinon une annulation attendrait et tuerait la prochaine étape de ce nom.
        if configuringRemotes.contains(name) {
            cancelledRemotes.insert(name)
            remotes?.cancelConfiguration(name)
        }
        if creatingRemotes.remove(name) != nil { try? await remotes?.delete(name) }
    }

    public func deleteRemote(_ name: String) async throws {
        let rclone = try configurator()
        try Self.checkName(name)
        creatingRemotes.remove(name)
        let users = tasks.filter { $0.remoteNames.contains(name) }.map(\.name).sorted()
        guard users.isEmpty else { throw AgentError.remoteInUse(users) }
        do { try await rclone.delete(name) } catch { throw Self.agentError(error) }
        await refreshRemoteTypes()
    }

    public func testRemote(_ name: String) async throws -> RemoteTestResult {
        try Self.checkName(name)
        return try await configurator().test(name)
    }

    public func listRemoteFolders(remote: String, path: String) async throws -> [String] {
        try Self.checkName(remote)
        try Self.checkValue(path)
        do { return try await configurator().folders(remote: remote, path: path) } catch { throw Self.agentError(error) }
    }

    /// Arrêt de l'agent : rclone est arrêté, puis les connexions à moitié créées sont supprimées.
    func stopRemoteConfigurations() async {
        guard let remotes else { return }
        remotes.cancelAll()
        await remotes.waitForIdle()
        let pending = creatingRemotes
        creatingRemotes.removeAll()
        for name in pending { try? await remotes.delete(name) }
    }

    /// Un nom bien formé pour rclone (déjà pris ou non) ; refus avant tout appel.
    static func checkName(_ name: String) throws {
        if let problem = RemoteNameRule.problem(name, existing: []) { throw AgentError.invalidRemote(message(problem)) }
    }

    /// Une valeur sur une seule ligne : un retour à la ligne s'écrirait tel quel dans `rclone.conf`.
    static func checkValue(_ value: String) throws {
        if value.contains(where: \.isNewline) {
            throw AgentError.invalidRemote("Une valeur ne peut pas contenir de retour à la ligne.")
        }
    }

    static func check(_ step: RemoteConfigStep) throws {
        try checkName(step.name)
        switch step {
        case .start(_, let type, let parameters):
            try checkValue(type)
            for (key, value) in parameters {
                try checkValue(key)
                try checkValue(value)
            }
        case .answer(_, let state, let result):
            try checkValue(state)
            try checkValue(result)
        case .reconnect:
            break
        }
    }

    static func message(_ problem: RemoteNameProblem) -> String {
        switch problem {
        case .empty: return "Donnez un nom à la connexion."
        case .invalidCharacters: return "Le nom ne peut contenir que des lettres, des chiffres, des espaces et _ - . + @."
        case .badStart: return "Le nom ne peut pas commencer par une espace ni par « - »."
        case .badEnd: return "Le nom ne peut pas finir par une espace."
        case .taken: return "Ce nom est déjà utilisé par une autre connexion."
        }
    }
}
