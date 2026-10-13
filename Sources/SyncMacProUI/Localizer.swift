import Foundation

/// Textes localisés (français = langue source, anglais) et mise en forme des tailles, débits et durées.
/// `language == nil` : langue du système. Une langue explicite sert aux tests.
public struct Localizer: Sendable {
    public let language: String?
    public let locale: Locale

    public init(language: String? = nil) {
        self.language = language
        locale = language.map { Locale(identifier: $0) } ?? .current
    }

    public static let system = Localizer()

    private var bundle: Bundle {
        guard let language, let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path) else { return Bundle.module }
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
