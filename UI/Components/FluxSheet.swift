import AppKit
import SwiftUI

private struct FluxSheetBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}

struct FluxSheet<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let subtitle: String?
    private let content: Content

    init(
        isPresented: Binding<Bool>,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        _isPresented = isPresented
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ZStack {
            if isPresented {
                ZStack {
                    FluxSheetBackdropView()
                    Color.white.opacity(0.04)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(FluxMotion.sheetAnimation) {
                        isPresented = false
                    }
                }
                .transition(.opacity)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(FluxTheme.textPrimary)

                            if let subtitle {
                                Text(subtitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(FluxTheme.textSecondary)
                            }
                        }

                        Spacer(minLength: 8)

                        Button {
                            withAnimation(FluxMotion.sheetAnimation) {
                                isPresented = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(FluxTheme.textTertiary)
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    content
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.94),
                                    .white.opacity(0.82)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.90), lineWidth: 1)
                )
                .shadow(color: Color(red: 0.15, green: 0.22, blue: 0.35).opacity(0.15), radius: 26, y: 10)
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(FluxMotion.sheetTransition)
            }
        }
        .animation(FluxMotion.sheetAnimation, value: isPresented)
    }
}
