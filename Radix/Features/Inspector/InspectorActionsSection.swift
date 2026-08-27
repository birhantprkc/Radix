import SwiftUI

struct InspectorActionBar: View {
    let revealAction: (() -> Void)?
    let discardPileAction: (() -> Void)?
    let discardPileTitle: String
    let discardPileSystemImageName: String

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

                if let discardPileAction {
                    Button {
                        discardPileAction()
                    } label: {
                        Label(discardPileTitle, systemImage: discardPileSystemImageName)
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
