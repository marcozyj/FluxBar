import SwiftUI

struct FluxInteractiveRow<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowBody
                }
                .buttonStyle(.plain)
            } else {
                rowBody
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }

    private var rowBody: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovering ? .white.opacity(0.78) : .white.opacity(0.66))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.84), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.05), radius: isHovering ? 12 : 8, y: 4)
            .offset(y: isHovering ? -1 : 0)
    }
}
