import SwiftUI

enum TopBannerPresentation {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }
}

private struct TopBannerSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 560)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

extension View {
    func topBannerSurface() -> some View {
        modifier(TopBannerSurfaceModifier())
    }

    func topBannerTransition() -> some View {
        transition(.move(edge: .top).combined(with: .opacity))
    }
}
