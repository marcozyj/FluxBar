import SwiftUI

@MainActor
enum FluxMotion {
    static let panelAnimation = Animation.spring(response: 0.55, dampingFraction: 0.90)
    static let cardAnimation = Animation.spring(response: 0.46, dampingFraction: 0.90)
    static let sheetAnimation = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let toastAnimation = Animation.spring(response: 0.28, dampingFraction: 0.88)
    static let tabAnimation = Animation.spring(response: 0.34, dampingFraction: 0.90)

    static let toastTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 10))
    static let sheetTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.965)).combined(with: .offset(y: -10))

    static func tabTransition(edge: Edge) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: edge)).combined(with: .scale(scale: 0.985)),
            removal: .opacity.combined(with: .move(edge: edge == .trailing ? .leading : .trailing))
        )
    }
}

private struct FluxEntranceModifier: ViewModifier {
    let animation: Animation
    let offsetY: CGFloat
    let scale: CGFloat
    let delay: Double

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : scale)
            .offset(y: isVisible ? 0 : offsetY)
            .onAppear {
                guard isVisible == false else {
                    return
                }

                withAnimation(animation.delay(delay)) {
                    isVisible = true
                }
            }
            .onDisappear {
                isVisible = false
            }
    }
}

extension View {
    func fluxPanelEntrance(delay: Double = 0) -> some View {
        modifier(
            FluxEntranceModifier(
                animation: FluxMotion.panelAnimation,
                offsetY: 10,
                scale: 0.965,
                delay: delay
            )
        )
    }

    func fluxCardEntrance(delay: Double = 0) -> some View {
        modifier(
            FluxEntranceModifier(
                animation: FluxMotion.cardAnimation,
                offsetY: 6,
                scale: 1,
                delay: delay
            )
        )
    }
}
