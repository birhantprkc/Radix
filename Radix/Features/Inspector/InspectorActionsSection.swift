import SwiftUI

enum InspectorLayout {
    static let formHorizontalMargin: CGFloat = 12
    static let groupedSectionHorizontalInset: CGFloat = 8
    static let actionHorizontalMargin = formHorizontalMargin + groupedSectionHorizontalInset
}

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
            .padding(.horizontal, InspectorLayout.actionHorizontalMargin)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(.bar)
        }
    }
}
