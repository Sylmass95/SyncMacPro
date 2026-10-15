import Foundation

/// Textes des mises à jour (Réglages, bannière), sans vue.
public struct UpdateText {
    public let localizer: Localizer

    public init(localizer: Localizer = .system) {
        self.localizer = localizer
    }

    public func state(_ state: UpdateState) -> String {
        switch state {
        case .idle: return ""
        case .checking: return localizer.text("update.checking")
        case .upToDate: return localizer.text("update.upToDate")
        case .downloading(let version): return localizer.format("update.downloading", version)
        case .ready(let version): return localizer.format("update.ready", version)
        case .installing: return localizer.text("update.installing")
        case .failed(let message): return localizer.format("update.failed", message)
        }
    }

    func banner(_ info: UpdateBannerInfo) -> String {
        localizer.format(info.waitingForCopies ? "update.banner.waiting" : "update.banner.ready", info.version)
    }
}
