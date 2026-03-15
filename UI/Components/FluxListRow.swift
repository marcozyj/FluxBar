import SwiftUI

struct FluxListRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let action: (() -> Void)?
    private let trailing: Trailing
    @State private var isHovering = false

    init(
        icon: String? = nil,
        title: String,
        subtitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.trailing = trailing()
    }

    init(
        icon: String? = nil,
        title: String,
        subtitle: String? = nil,
        action: (() -> Void)? = nil
    ) where Trailing == EmptyView {
        self.init(icon: icon, title: title, subtitle: subtitle, action: action, trailing: { EmptyView() })
    }

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
    }

    private var rowBody: some View {
        HStack(spacing: 10) {
            if let icon {
                Text(icon)
                    .font(.system(size: 16))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.94, green: 0.96, blue: 1.0),
                                        Color(red: 0.87, green: 0.91, blue: 0.97)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.white.opacity(0.78), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(FluxTheme.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FluxTheme.textSecondary)
                }
            }

            Spacer(minLength: 10)
            trailing
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isHovering ? .white.opacity(0.78) : .white.opacity(0.64)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.84), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.05), radius: isHovering ? 12 : 8, y: 4)
        .offset(y: isHovering ? -1 : 0)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
