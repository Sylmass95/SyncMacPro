import Foundation

/// Textes localisés (français = langue source, anglais) et mise en forme des tailles, débits et durées.
/// `language == nil` : langue du système. Une langue explicite sert aux tests.
public struct Localizer: Sendable {
    public let language: String?
    public let locale: Locale
    /// Dossier des ressources de l'interface (fichiers `.strings`).
    let resourcesURL: URL

    public init(language: String? = nil) {
        self.init(language: language, resourcesURL: Self.defaultResourcesURL)
    }

    init(language: String?, resourcesURL: URL) {
        self.language = language
        self.resourcesURL = resourcesURL
        locale = language.map { Locale(identifier: $0) } ?? .current
    }

    public static let system = Localizer()

    static let resourceBundleName = "SyncMacPro_SyncMacProUI"
    static let defaultResourcesURL = resourcesURL(in: .main)

    /// Dans l'app : `Contents/Resources/SyncMacPro_SyncMacProUI.bundle`. Hors de l'app (tests, `swift run`) : `Bundle.module`.
    /// L'accesseur généré par SwiftPM ne cherche qu'à la racine de l'app puis dans le dossier `.build` d'origine,
    /// et plante si aucun n'existe : une app copiée sur un autre Mac planterait au lancement.
    static func resourcesURL(in app: Bundle) -> URL {
        app.url(forResource: resourceBundleName, withExtension: "bundle") ?? Bundle.module.bundleURL
    }

    private var bundle: Bundle {
        let base = Bundle(url: resourcesURL) ?? Bundle.main
        guard let language, let path = base.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path) else { return base }
        return localized
    }

    /// Une clé inconnue s'affiche « ⚠︎clé » : visible à l'écran et attrapée par le test de complétude.
    public func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: "⚠︎\(key)", table: nil)
    }

    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    /// 512 → « 512 o », 5 242 880 → « 5,0 Mo » (« 5.0 MB » en anglais).
    public func bytes(_ value: Int64) -> String {
        let number = Double(value)
        let units = ["unit.byte", "unit.kilobyte", "unit.megabyte", "unit.gigabyte", "unit.terabyte"]
        let digits = [0, 0, 1, 2, 2]
        var scaled = max(number, 0)
        var index = 0
        while scaled >= 1_024, index < units.count - 1 {
            scaled /= 1_024
            index += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = digits[index]
        formatter.maximumFractionDigits = digits[index]
        let figure = formatter.string(from: NSNumber(value: scaled)) ?? "\(Int(scaled))"
        return "\(figure) \(text(units[index]))"
    }

    public func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// 65 → « 1:05 », 3725 → « 1:02:05 ».
    public func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
