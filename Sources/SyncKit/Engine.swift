import Foundation

/// Les deux programmes que SyncMacPro pilote.
public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case rsync
    case rclone
}
