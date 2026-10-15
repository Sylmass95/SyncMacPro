import Foundation

/// Un fichier de 0 octet à la source ne remplace jamais une version non vide à la destination : c'est presque toujours
/// un fichier que Drive pour ordinateur n'a pas fini d'envoyer (essai réel du 15/10 : un .psb de 6,5 Go à 0 octet,
/// copié vide sur le NAS). Un fichier vide nouveau, lui, est copié.
public enum EmptySourceGuard {
    public static func protectedPaths(sourceEmpty: [String], destinationSizes: [String: Int64]) -> [String] {
        sourceEmpty.filter { (destinationSizes[$0] ?? 0) > 0 }.sorted()
    }

    public static func message(count: Int) -> String {
        "\(count) fichier(s) vide(s) à la source non copié(s) : la destination a une version non vide (voir le journal)."
    }

    /// Fichier d'exclusions (un chemin ancré par ligne) dans le dossier temporaire ; `nil` s'il n'y a rien à exclure.
    static func excludeFile(_ paths: [String], escape: (String) -> String) -> String? {
        guard !paths.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smp-vides-\(UUID().uuidString).txt")
        let lines = paths.map { "/" + escape($0) }
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url.path
    }

    /// Motifs rsync : `*`, `?`, `[` et `\` sont spéciaux.
    static func rsyncEscape(_ path: String) -> String { escape(path, special: "*?[\\") }

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

    /// Fichiers vides d'une source sur le disque (dossier entier ou éléments choisis), en chemins relatifs à la source.
    static func emptyFiles(in source: String, items: [String]) -> [String] {
        let roots = items.isEmpty ? [""] : items.map { PathText.withoutTrailingSlash($0) }
        var result: [String] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        for root in roots {
            let base = URL(fileURLWithPath: Endpoint.join(source, root))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if (try? base.resourceValues(forKeys: Set(keys)))?.fileSize == 0 { result.append(root) }
                continue
            }
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else { continue }
            let prefix = base.standardizedFileURL.path + "/"
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      values.fileSize == 0 else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                result.append(root.isEmpty ? relative : Endpoint.join(root, relative))
            }
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
