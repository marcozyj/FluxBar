import SwiftUI

struct FluxToggle: View {
    @Binding var isOn: Bool
    var isEnabled = true
    var isLoading = false

    var body: some View {
        Button {
            guard isEnabled else {
                return
            }

            withAnimation(.easeInOut(duration: 0.22)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(FluxTheme.accentFill) : AnyShapeStyle(Color(red: 0.74, green: 0.78, blue: 0.84)))
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.82), lineWidth: 1)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .padding(3)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(FluxTheme.textPrimary)
                }
            }
            .frame(width: 50, height: 30)
            .opacity(isEnabled ? 1.0 : 0.7)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
    }
}
