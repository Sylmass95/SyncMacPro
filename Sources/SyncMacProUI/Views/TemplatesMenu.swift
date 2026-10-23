import SwiftUI
import SyncKit

@MainActor
struct TemplatesMenu: View {
    let localizer: Localizer
    let onPick: (TaskTemplate) -> Void

    var body: some View {
        let text = TaskSummaryText(localizer: localizer)
        Menu(localizer.text("tasks.templates")) {
            ForEach(TaskTemplate.allCases) { template in
                Button {
                    onPick(template)
                } label: {
                    Text(text.templateTitle(template))
                    Text(text.templateDescription(template))
                }
            }
        }
        .fixedSize()
    }
}
