import Foundation

/// Arguments des commandes de configuration de rclone. `config` : fichier à utiliser (`nil` : celui de rclone).
public enum RcloneConfigCommand {
    static func configArguments(_ config: String?) -> [String] { config.map { ["--config", $0] } ?? [] }

    public static func listRemotes(config: String?) -> [String] {
        ["listremotes", "--long", "--json"] + configArguments(config)
    }

    public static func arguments(for step: RemoteConfigStep, config: String?) -> [String] {
        let base: [String]
        switch step {
        case .start(let name, let type, let parameters):
            base = ["config", "create", name, type] + parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }
        case .answer(let name, let state, let result):
            base = ["config", "update", name, "--continue", "--state", state, "--result", result]
        case .reconnect(let name):
            base = ["config", "update", name, "config_refresh_token=true"]
        }
        return base + ["--non-interactive"] + configArguments(config)
    }

    public static func delete(_ name: String, config: String?) -> [String] {
        ["config", "delete", name] + configArguments(config)
    }

    public static func test(_ name: String, config: String?) -> [String] {
        folders(remote: name, path: "", config: config)
    }

    public static func folders(remote: String, path: String, config: String?) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ["lsjson", "\(remote):\(trimmed)", "--dirs-only", "--max-depth", "1"] + configArguments(config)
    }
}
