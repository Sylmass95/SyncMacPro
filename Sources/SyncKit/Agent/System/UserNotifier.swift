import Foundation
import UserNotifications

/// Notifications macOS. Elles exigent que l'agent appartienne à un bundle d'app ; sinon (outil lancé à la main),
/// le message part sur la sortie d'erreur.
public final class UserNotifier: AgentNotifier, @unchecked Sendable {
    private let fallback: @Sendable (String) -> Void

    public init(fallback: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.fallback = fallback
    }

    public func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            fallback("\(title) — \(body)")
            return
        }
        let center = UNUserNotificationCenter.current()
        let fallback = self.fallback
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                fallback("\(title) — \(body)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
