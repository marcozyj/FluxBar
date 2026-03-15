import SwiftUI

enum FluxBadgeStyle {
    case soft
    case solid
}

struct FluxBadge: View {
    let title: String
    var tone: FluxTone = .accent
    var style: FluxBadgeStyle = .soft
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }

            Text(title)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(foregroundColor)
        .frame(minHeight: 26)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundStyle, in: Capsule())
        .overlay(
            Capsule()
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var foregroundColor: Color {
        switch style {
        case .soft:
            return FluxTheme.chipForeground(for: tone)
        case .solid:
            return .white
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch style {
        case .soft:
            return AnyShapeStyle(FluxTheme.chipBackground(for: tone))
        case .solid:
            switch tone {
            case .neutral:
                return AnyShapeStyle(Color(red: 0.28, green: 0.34, blue: 0.43))
            case .accent:
                return AnyShapeStyle(FluxTheme.accentFill)
            case .positive:
                return AnyShapeStyle(FluxTheme.good)
            case .warning:
                return AnyShapeStyle(FluxTheme.warning)
            case .critical:
                return AnyShapeStyle(FluxTheme.critical)
            }
        }
    }

    private var borderColor: Color {
        switch style {
        case .soft:
            return FluxTheme.chipBorder(for: tone)
        case .solid:
            return .white.opacity(0.20)
        }
    }
}
