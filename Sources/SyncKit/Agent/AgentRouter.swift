import Foundation

/// Traduit une requête XPC en appel à `AgentCore`. Séparé du transport pour être testable sans XPC.
public enum AgentRouter {
    private struct VersionProbe: Decodable { let version: Int }

    public static func handle(_ data: Data, core: AgentCore) async -> Data {
        reply(await response(for: data, core: core))
    }

    private static func response(for data: Data, core: AgentCore) async -> AgentResponse {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return .error(.internalFailure("requête illisible"))
        }
        guard probe.version == agentProtocolVersion else {
            return .error(.versionMismatch(agent: agentProtocolVersion, client: probe.version))
        }
        guard let envelope = try? JSONDecoder().decode(AgentRequestEnvelope.self, from: data) else {
            return .error(.internalFailure("requête illisible"))
        }
        do {
            switch envelope.request {
            case .status: return .status(await core.status())
            case .listTasks: return .tasks(await core.listTasks())
            case .history(let id, let limit): return .history(try await core.runHistory(taskID: id, limit: limit))
            case .runNow(let id): try await core.runNow(id)
            case .pause(let id): try await core.pause(id)
            case .resume(let id): try await core.resume(id)
            case .stop(let id): try await core.stop(id)
            case .setGlobalPause(let paused): await core.setGlobalPause(paused)
            case .approveDeletion(let id): try await core.approveDeletion(id)
            case .reloadTasks: await core.reloadTasks()
            case .saveTask(let task): try await core.saveTask(task)
            case .removeTask(let id): try await core.removeTask(id)
            case .simulate(let task): return .simulation(try await core.simulate(task))
            case .cancelSimulation(let id): await core.cancelSimulation(id)
            case .runLog(let id, let maxBytes): return .log(try await core.runLog(runID: id, maxBytes: maxBytes))
            case .runOnce(let task): try await core.runOnce(task)
            case .listRemotes: return .remotes(try await core.listRemotes())
            case .configureRemote(let step): return .remoteConfig(try await core.configureRemote(step))
            case .cancelRemoteConfiguration(let name): await core.cancelRemoteConfiguration(name)
            case .deleteRemote(let name): try await core.deleteRemote(name)
            case .testRemote(let name): return .remoteTest(try await core.testRemote(name))
            case .listRemoteFolders(let remote, let path):
                return .folders(try await core.listRemoteFolders(remote: remote, path: path))
            case .clearHistory(let id): return .cleared(try await core.clearHistory(taskID: id))
            case .enqueue(let id): try await core.enqueue(id)
            case .enqueueOnce(let task): try await core.enqueueOnce(task)
            case .dequeue(let id): try await core.dequeue(id)
            case .moveInQueue(let id, let index): try await core.moveInQueue(id, to: index)
            case .setQueueRunning(let running): await core.setQueueRunning(running)
            case .setBandwidth(let limits): await core.setBandwidth(limits)
            case .abandonSuspended(let id): try await core.abandonSuspended(id)
            case .ejectDrive(let id): try await core.ejectDrive(id)
            case .checkAccess:
                // Les demandes de macOS attendent l'utilisateur : la réponse n'attend pas.
                Task { await core.checkAccess() }
            }
            return .ok
        } catch let error as AgentError {
            return .error(error)
        } catch {
            return .error(.internalFailure("\(error)"))
        }
    }

    private static func reply(_ response: AgentResponse) -> Data {
        let envelope = AgentResponseEnvelope(response: response)
        return (try? JSONEncoder().encode(envelope))
            ?? Data("{\"version\":\(agentProtocolVersion),\"response\":{\"error\":{\"internalFailure\":{\"_0\":\"réponse non encodable\"}}}}".utf8)
    }
}
