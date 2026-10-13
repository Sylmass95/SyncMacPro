import Darwin
import Foundation

// MARK: serveur

/// Un objet par connexion : traduit les appels XPC et retire ses observateurs à la fermeture.
final class AgentConnectionHandler: NSObject, AgentXPCProtocol, @unchecked Sendable {
    private let core: AgentCore
    private let lock = NSLock()
    private var tokens: [UUID] = []
    private var closed = false

    init(core: AgentCore) { self.core = core }

    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let core = self.core
        Task { reply(await AgentRouter.handle(data, core: core)) }
    }

    func subscribe(_ observer: AgentObserverXPC, reply: @escaping () -> Void) {
        let core = self.core
        Task {
            let token = await core.addObserver { event in
                if let data = try? JSONEncoder().encode(event) { observer.event(data) }
            }
            // La connexion est déjà fermée : personne n'écoutera, on ne laisse pas l'observateur traîner.
            if !register(token) { await core.removeObserver(token) }
            reply()
        }
    }

    /// Faux si la connexion est déjà fermée. Synchrone : le verrou ne traverse jamais un `await`.
    private func register(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        tokens.append(token)
        return true
    }

    func tearDown() {
        lock.lock()
        closed = true
        let pending = tokens
        tokens = []
        lock.unlock()
        let core = self.core
        Task { for token in pending { await core.removeObserver(token) } }
    }
}

public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let core: AgentCore
    private let requirement: String?
    var onNewConnection: ((NSXPCConnection) -> Void)?

    /// `codeSigningRequirement` : exigence de signature du client (app signée avec une équipe) ;
    /// `nil` en signature ad hoc, où l'on se limite au même utilisateur.
    public init(core: AgentCore, codeSigningRequirement: String? = nil) {
        self.core = core
        requirement = codeSigningRequirement
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        let handler = AgentConnectionHandler(core: core)
        connection.exportedInterface = AgentXPC.makeInterface()
        connection.exportedObject = handler
        connection.remoteObjectInterface = NSXPCInterface(with: AgentObserverXPC.self)
        connection.invalidationHandler = { handler.tearDown() }
        onNewConnection?(connection)
        connection.resume()
        return true
    }
}

// MARK: client

public enum AgentClientError: Error, LocalizedError, Equatable {
    /// L'agent ne répond pas (non installé, arrêté, ou pas encore relancé par launchd).
    case unreachable
    case badReply
    case agent(AgentError)

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "L'agent ne répond pas. Installez-le avec « syncmacpro-ctl agent install » ou attendez quelques secondes."
        case .badReply: return "Réponse de l'agent illisible."
        case .agent(let error): return error.errorDescription
        }
    }
}

/// Résultat unique d'un appel XPC : réponse, erreur de connexion ou délai écoulé, au premier arrivé.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

final class ClientObserver: NSObject, AgentObserverXPC, @unchecked Sendable {
    private let handler: @Sendable (AgentEvent) -> Void

    init(_ handler: @escaping @Sendable (AgentEvent) -> Void) { self.handler = handler }

    func event(_ data: Data) {
        if let event = try? JSONDecoder().decode(AgentEvent.self, from: data) { handler(event) }
    }
}

public final class AgentWatch: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let observer: ClientObserver
    private let cancelled: Locked<Bool>

    init(connection: NSXPCConnection, observer: ClientObserver, cancelled: Locked<Bool>) {
        self.connection = connection
        self.observer = observer
        self.cancelled = cancelled
    }

    /// Fin volontaire : `onEnd` n'est pas appelé.
    public func cancel() {
        cancelled.set(true)
        connection.invalidate()
    }
}

public final class AgentClient: @unchecked Sendable {
    public typealias ConnectionFactory = @Sendable () -> NSXPCConnection

    private let factory: ConnectionFactory
    private let timeout: TimeInterval

    /// `timeout` : après un arrêt brutal, launchd met environ 10 s à relancer l'agent ; 20 s laissent la marge.
    public init(timeout: TimeInterval = 20, connectionFactory: @escaping ConnectionFactory) {
        self.timeout = timeout
        factory = connectionFactory
    }

    public static func machService(_ name: String = AgentIdentifiers.machService, timeout: TimeInterval = 20) -> AgentClient {
        AgentClient(timeout: timeout) { NSXPCConnection(machServiceName: name) }
    }

    // MARK: appels

    public func send(_ request: AgentRequest, timeout: TimeInterval? = nil) async throws -> AgentResponse {
        let payload = try JSONEncoder().encode(AgentRequestEnvelope(request: request))
        let reply = try await sendRaw(payload, timeout: timeout)
        struct Probe: Decodable { let version: Int }
        if let probe = try? JSONDecoder().decode(Probe.self, from: reply), probe.version != agentProtocolVersion {
            throw AgentClientError.agent(.versionMismatch(agent: probe.version, client: agentProtocolVersion))
        }
        guard let envelope = try? JSONDecoder().decode(AgentResponseEnvelope.self, from: reply) else {
            throw AgentClientError.badReply
        }
        if case .error(let error) = envelope.response { throw AgentClientError.agent(error) }
        return envelope.response
    }

    func sendRaw(_ data: Data, timeout: TimeInterval? = nil) async throws -> Data {
        let connection = factory()
        connection.remoteObjectInterface = AgentXPC.makeInterface()
        connection.resume()
        defer { connection.invalidate() }
        let timeout = timeout ?? self.timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let shot = OneShot(continuation)
            let timer = DispatchWorkItem { shot.finish(.failure(AgentClientError.unreachable)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                timer.cancel()
                shot.finish(.failure(AgentClientError.unreachable))
            } as? AgentXPCProtocol
            guard let proxy else {
                timer.cancel()
                shot.finish(.failure(AgentClientError.unreachable))
                return
            }
            proxy.request(data) { reply in
                timer.cancel()
                shot.finish(.success(reply))
            }
        }
    }

    /// Une simulation peut durer : 15 minutes avant d'abandonner.
    public func simulate(_ task: SyncTask) async throws -> SimulationResult {
        guard case .simulation(let result) = try await send(.simulate(task), timeout: 900) else {
            throw AgentClientError.badReply
        }
        return result
    }

    public func status() async throws -> AgentStatus {
        guard case .status(let status) = try await send(.status) else { throw AgentClientError.badReply }
        return status
    }

    public func listTasks() async throws -> [SyncTask] {
        guard case .tasks(let tasks) = try await send(.listTasks) else { throw AgentClientError.badReply }
        return tasks
    }

    public func history(taskID: UUID?, limit: Int) async throws -> [RunRecord] {
        guard case .history(let records) = try await send(.history(taskID: taskID, limit: limit)) else {
            throw AgentClientError.badReply
        }
        return records
    }

    /// Commande sans résultat (lancer, pause, reprise, arrêt, pause globale, validation, rechargement).
    public func perform(_ request: AgentRequest) async throws {
        _ = try await send(request)
    }

    /// Reçoit les événements de l'agent. `onEnd` est appelé quand la connexion est coupée ou interrompue
    /// (l'agent s'est arrêté : l'abonnement est perdu et il faut se reconnecter), jamais après `cancel()`.
    public func watch(
        _ onEvent: @escaping @Sendable (AgentEvent) -> Void,
        onEnd: @escaping @Sendable () -> Void = {}
    ) async throws -> AgentWatch {
        let connection = factory()
        let observer = ClientObserver(onEvent)
        let cancelled = Locked(false)
        let end: @Sendable () -> Void = { if !cancelled.get() { onEnd() } }
        connection.invalidationHandler = end
        connection.interruptionHandler = {
            end()
            connection.invalidate()
        }
        connection.remoteObjectInterface = AgentXPC.makeInterface()
        connection.exportedInterface = NSXPCInterface(with: AgentObserverXPC.self)
        connection.exportedObject = observer
        connection.resume()
        let timeout = self.timeout
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shot = OneShot(continuation)
                let timer = DispatchWorkItem { shot.finish(.failure(AgentClientError.unreachable)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    timer.cancel()
                    shot.finish(.failure(AgentClientError.unreachable))
                } as? AgentXPCProtocol
                guard let proxy else {
                    timer.cancel()
                    shot.finish(.failure(AgentClientError.unreachable))
                    return
                }
                proxy.subscribe(observer) {
                    timer.cancel()
                    shot.finish(.success(()))
                }
            }
        } catch {
            cancelled.set(true)
            connection.invalidate()
            throw error
        }
        return AgentWatch(connection: connection, observer: observer, cancelled: cancelled)
    }
}
