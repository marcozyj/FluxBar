import SwiftUI

struct FluxCard<Trailing: View, Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let trailing: Trailing
    private let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) where Trailing == EmptyView {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title {
                            Text(title)
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(FluxTheme.textPrimary)
                        }

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(FluxTheme.textSecondary)
                        }
                    }

                    Spacer(minLength: 8)
                    trailing
                }
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FluxTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.90), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.18, green: 0.25, blue: 0.39).opacity(0.09), radius: 14, y: 6)
        .fluxCardEntrance()
    }
}
