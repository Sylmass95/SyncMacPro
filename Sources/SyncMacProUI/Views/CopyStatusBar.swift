import SwiftUI
import SyncKit

public enum SizeState: Equatable, Sendable {
    case none
    case computing
    case done(SizeTotal)
    case failed
}

/// En bas de l'écran Copie : la sélection, sa taille, la place libre à destination.
@MainActor
struct CopyStatusBar: View {
    let count: Int
    let size: SizeState
    let free: Int64?
    let localizer: Localizer

    static func sizeText(_ size: SizeState, localizer l: Localizer) -> String? {
        switch size {
        case .none: return nil
        case .computing: return l.text("copy.size.computing")
        case .failed: return l.text("copy.size.failed")
        case .done(let total): return l.format("copy.size.done", total.files, l.bytes(total.bytes))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(count == 0 ? localizer.text("copy.selection.none") : localizer.format("copy.selection.count", count))
            if let size = Self.sizeText(size, localizer: localizer) {
                Text("·").foregroundStyle(.tertiary)
                Text(size)
            }
            Spacer()
            if let free {
                Label(localizer.format("copy.free", localizer.bytes(free)), systemImage: "internaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
