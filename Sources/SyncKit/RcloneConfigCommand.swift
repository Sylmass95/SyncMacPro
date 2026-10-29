import Foundation

/// Arguments des commandes de configuration de rclone. `config` : fichier à utiliser (`nil` : celui de rclone).
public enum RcloneConfigCommand {
    static func configArguments(_ config: String?) -> [String] { config.map { ["--config", $0] } ?? [] }

    public static func listRemotes(config: String?) -> [String] {
        ["listremotes", "--long", "--json"] + configArguments(config)
    }

    /// Les options d'abord, puis `--` : un nom ou une valeur commençant par « - » n'est jamais lu comme une option.
    public static func arguments(for step: RemoteConfigStep, config: String?) -> [String] {
        switch step {
        case .start(let name, let type, let parameters):
            // 1.8.10 : un mot de passe est toujours chiffré par rclone (sans `--obscure`, il devine s'il l'est déjà).
            let obscure = parameters["pass"] != nil ? ["--obscure"] : []
            return ["config", "create", "--non-interactive"] + obscure + configArguments(config) + ["--", name, type]
                + parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }
        case .answer(let name, let state, let result):
            return ["config", "update", "--continue", "--state", state, "--result", result, "--non-interactive"]
                + configArguments(config) + ["--", name]
        case .reconnect(let name):
            return ["config", "update", "--non-interactive"] + configArguments(config) + ["--", name, "config_refresh_token=true"]
        }
    }

    public static func delete(_ name: String, config: String?) -> [String] {
        ["config", "delete"] + configArguments(config) + ["--", name]
    }

    public static func test(_ name: String, config: String?) -> [String] {
        folders(remote: name, path: "", config: config)
    }

    public static func folders(remote: String, path: String, config: String?) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ["lsjson", "--dirs-only", "--max-depth", "1"] + configArguments(config) + ["--", "\(remote):\(trimmed)"]
    }
}
