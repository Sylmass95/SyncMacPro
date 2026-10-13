import AppKit
import SwiftUI
import SyncKit

@MainActor
struct RunLogSheet: View {
    let model: AgentModel
    let record: RunRecord
    let localizer: Localizer
    let onClose: () -> Void
    @State private var outcome: LogOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.format("log.title", record.taskName)).font(.headline)
            ScrollView { RunLogContent(outcome: outcome, localizer: localizer) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(localizer.text("log.copy")) {
                    if case .loaded(let log) = outcome {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.text, forType: .string)
                    }
                }
                .disabled(!isLoaded)
                Spacer()
                Button(localizer.text("log.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 780, height: 540)
        .background(GlassBackdrop())
        .glassThemed()
        .task { outcome = await model.runLog(record.id) }
    }

    private var isLoaded: Bool {
        if case .loaded = outcome { return true }
        return false
    }
}

/// Le contenu du journal, sans défilement (rendu par les tests).
@MainActor
struct RunLogContent: View {
    let outcome: LogOutcome?
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch outcome {
            case nil:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(localizer.text("log.loading"))
                }
            case .loaded(let log)?:
                if log.truncated {
                    Text(localizer.text("log.truncated")).font(.caption).foregroundStyle(.secondary)
                }
                Text(log.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .missing?:
                Text(localizer.text("log.none")).foregroundStyle(.secondary)
            case .failed(let message)?:
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
