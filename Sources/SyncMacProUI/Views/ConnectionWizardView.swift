import SwiftUI
import SyncKit

/// Feuille de l'assistant (version minimale, remplacée à la tâche suivante).
@MainActor
struct ConnectionWizardView: View {
    let wizard: WizardModel
    let localizer: Localizer
    let onClose: () -> Void

    var body: some View {
        VStack {
            Text(localizer.text("connections.add"))
            Button(localizer.text("confirm.cancel"), action: onClose)
        }
        .padding(20)
    }
}
