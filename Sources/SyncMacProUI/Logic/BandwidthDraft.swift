import Foundation
import SyncKit

/// Saisie des plafonds (Mbit/s, virgule acceptée) ; interrupteur éteint = sans plafond.
public struct BandwidthDraft: Equatable {
    public var downloadOn: Bool
    public var uploadOn: Bool
    public var localOn: Bool
    public var downloadText: String
    public var uploadText: String
    public var localText: String

    public init(_ limits: BandwidthLimits?) {
        func text(_ value: Double?) -> String {
            guard let value else { return "" }
            if value.rounded() == value { return String(Int(value)) }
            return String(value).replacingOccurrences(of: ".", with: ",")
        }
        downloadOn = limits?.downloadMbps != nil
        uploadOn = limits?.uploadMbps != nil
        localOn = limits?.localMbps != nil
        downloadText = text(limits?.downloadMbps)
        uploadText = text(limits?.uploadMbps)
        localText = text(limits?.localMbps)
    }

    /// Valeur d'un champ : `.some(nil)` éteint, `.some(n)` valide, `nil` invalide.
    static func value(_ on: Bool, _ text: String) -> Double?? {
        guard on else { return .some(nil) }
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(cleaned), number > 0 else { return nil }
        return .some(number)
    }

    /// `nil` si un champ activé n'est pas un nombre positif.
    public var limits: BandwidthLimits? {
        guard let down = Self.value(downloadOn, downloadText), let up = Self.value(uploadOn, uploadText),
              let local = Self.value(localOn, localText) else { return nil }
        return BandwidthLimits(downloadMbps: down, uploadMbps: up, localMbps: local)
    }
}
