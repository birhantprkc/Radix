import SwiftUI

struct InspectorActionBar: View {
    let revealAction: (() -> Void)?
    let addToDiscardPileAction: (() -> Void)?
    let addToDiscardPileTitle: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 8) {
                if let revealAction {
                    Button {
                        revealAction()
                    } label: {
                        Label(
                            FileNodeAction.revealInFinder.title,
                            systemImage: FileNodeAction.revealInFinder.systemImageName
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if let addToDiscardPileAction {
                    Button {
                        addToDiscardPileAction()
                    } label: {
                        Label(addToDiscardPileTitle, systemImage: "checklist")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
