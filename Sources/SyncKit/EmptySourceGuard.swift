import Foundation

/// Un fichier de 0 octet à la source ne remplace jamais une version non vide à la destination : c'est presque toujours
/// un fichier que Drive pour ordinateur n'a pas fini d'envoyer (essai réel du 15/10 : un .psb de 6,5 Go à 0 octet,
/// copié vide sur le NAS). Un fichier vide nouveau, lui, est copié.
public enum EmptySourceGuard {
    public static func protectedPaths(sourceEmpty: [String], destinationSizes: [String: Int64]) -> [String] {
        sourceEmpty.filter { (destinationSizes[$0] ?? 0) > 0 }.sorted()
    }

    /// 1.8.3 : synchronisation bidirectionnelle, la version pleine a remplacé la copie vide de l'autre côté.
    public static func repairedMessage(count: Int) -> String {
        "\(count) copie(s) vide(s) réparée(s) avec la version pleine de l'autre côté (voir le journal)."
    }

    public static func message(count: Int) -> String {
        "\(count) fichier(s) vide(s) à la source non copié(s) : la destination a une version non vide (voir le journal)."
    }

    /// Fichier d'exclusions (un chemin ancré par ligne) dans le dossier temporaire ; `nil` s'il n'y a rien à exclure.
    /// `bothForms` (rsync par SSH, 1.8.1) : chaque chemin sous ses deux formes Unicode, rsync ne convertissant pas les
    /// motifs avec --iconv.
    static func excludeFile(_ paths: [String], escape: (String) -> String, bothForms: Bool = false) -> String? {
        guard !paths.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smp-vides-\(UUID().uuidString).txt")
        let lines = (bothForms ? SSHAccess.bothForms(paths) : paths).map { "/" + escape($0) }
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url.path
    }

    /// Motifs rsync : `*`, `?`, `[` et `\` sont spéciaux.
    /// rsync ne lit « \\ » comme échappement que dans un motif qui contient `*`, `?` ou `[` : ailleurs, le chemin
    /// est rendu tel quel.
    static func rsyncEscape(_ path: String) -> String {
        guard path.contains(where: { "*?[".contains($0) }) else { return path }
        return escape(path, special: "*?[\\")
    }

    /// Motifs rclone : `*`, `?`, `[`, `]`, `{`, `}` et `\` sont spéciaux.
    static func rcloneEscape(_ path: String) -> String { escape(path, special: "*?[]{}\\") }

    private static func escape(_ path: String, special: String) -> String {
        var result = ""
        for character in path {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Tailles à la destination sur le disque des chemins donnés (absents : ignorés).
    static func sizes(of paths: [String], in destination: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for path in paths {
            if let size = (try? FileManager.default.attributesOfItem(atPath: Endpoint.join(destination, path))[.size] as? NSNumber)?.int64Value {
                sizes[path] = size
            }
        }
        return sizes
    }
}
