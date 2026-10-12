import Foundation

/// Découpe un flux de texte en lignes, sur « \n » comme sur « \r ».
/// rsync met à jour sa progression avec « \r » (sans retour à la ligne) : chaque mise à jour est une ligne.
public struct LineSplitter: Sendable {
    private var pending = ""

    public init() {}

    /// Ajoute un morceau de texte et retourne les lignes complètes (non vides, sans espaces autour).
    public mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var lines: [String] = []
        var current = ""
        for character in pending {
            if character == "\n" || character == "\r" || character == "\r\n" {
                let line = current.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { lines.append(line) }
                current = ""
            } else {
                current.append(character)
            }
        }
        pending = current
        return lines
    }

    /// Retourne la dernière ligne, même sans retour à la ligne final.
    public mutating func finish() -> [String] {
        let line = pending.trimmingCharacters(in: .whitespaces)
        pending = ""
        return line.isEmpty ? [] : [line]
    }

    /// Commodité pour un texte complet.
    public static func lines(in text: String) -> [String] {
        var splitter = LineSplitter()
        return splitter.feed(text) + splitter.finish()
    }
}
