import SwiftUI

struct InspectorNoSelectionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing Selected", systemImage: "cursorarrow.click")
        } description: {
            Text("Select an item in the disk map or file browser to inspect it.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
