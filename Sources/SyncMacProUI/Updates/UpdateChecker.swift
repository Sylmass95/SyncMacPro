import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let url: URL
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo)
    case failed(String)
}

/// Lit la dernière publication GitHub ; n'installe rien.
public struct UpdateChecker: Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/Sylmass95/SyncMacPro/releases/latest")!
    public static let interval: TimeInterval = 86_400

    let current: SemanticVersion?
    let fetch: @Sendable (URL) async throws -> (Data, Int)

    public init(current: String, fetch: @escaping @Sendable (URL) async throws -> (Data, Int) = UpdateChecker.network) {
        self.current = SemanticVersion(current)
        self.fetch = fetch
    }

    public static let network: @Sendable (URL) async throws -> (Data, Int) = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func check() async -> UpdateCheckResult {
        do {
            let (data, status) = try await fetch(Self.latestURL)
            return Self.parse(data, status: status, current: current)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public static func parse(_ data: Data, status: Int, current: SemanticVersion?) -> UpdateCheckResult {
        if status == 404 { return .upToDate }   // aucune publication encore
        struct Release: Decodable {
            var tag_name: String
            var html_url: String
            var draft: Bool?
            var prerelease: Bool?
        }
        guard status == 200 else {
            struct Message: Decodable { var message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? "HTTP \(status)"
            return .failed(message)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let version = SemanticVersion(release.tag_name), let url = URL(string: release.html_url)
        else { return .failed("réponse illisible") }
        guard release.draft != true, release.prerelease != true, let current, current < version else { return .upToDate }
        return .available(ReleaseInfo(version: version, url: url))
    }

    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }
}
