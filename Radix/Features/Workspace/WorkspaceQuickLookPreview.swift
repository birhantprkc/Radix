import QuickLook
import SwiftUI

struct WorkspaceQuickLookPreview: ViewModifier {
    @ObservedObject var controller: AppQuickLookController

    func body(content: Content) -> some View {
        content.quickLookPreview(
            Binding(
                get: { controller.session?.selection },
                set: { controller.setPreviewSelection($0) }
            ),
            in: controller.session?.urls ?? []
        )
    }
}
