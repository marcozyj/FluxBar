import SwiftUI

enum FluxTone {
    case neutral
    case accent
    case positive
    case warning
    case critical
}

enum FluxTheme {
    static let textPrimary = Color(red: 0.07, green: 0.14, blue: 0.23)
    static let textSecondary = Color(red: 0.38, green: 0.44, blue: 0.54)
    static let textTertiary = Color(red: 0.22, green: 0.29, blue: 0.38)

    static let accentTop = Color(red: 0.13, green: 0.51, blue: 1.0)
    static let accentBottom = Color(red: 0.05, green: 0.43, blue: 0.97)
    static let good = Color(red: 0.13, green: 0.71, blue: 0.44)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.10)
    static let critical = Color(red: 1.0, green: 0.37, blue: 0.34)

    static let pageBackgroundTop = Color(red: 0.91, green: 0.94, blue: 0.98)
    static let pageBackgroundBottom = Color(red: 0.84, green: 0.89, blue: 0.96)
    static let viewportFill = Color.white.opacity(0.70)

    static let cardFill = LinearGradient(
        colors: [
            .white.opacity(0.99),
            .white.opacity(0.93)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let controlFill = LinearGradient(
        colors: [
            .white.opacity(0.96),
            .white.opacity(0.82)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let elevatedFill = LinearGradient(
        colors: [
            .white.opacity(0.98),
            .white.opacity(0.88)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let accentFill = LinearGradient(
        colors: [
            accentTop,
            accentBottom
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static func chipForeground(for tone: FluxTone) -> Color {
        switch tone {
        case .neutral:
            return Color(red: 0.20, green: 0.27, blue: 0.37)
        case .accent:
            return Color(red: 0.09, green: 0.27, blue: 0.48)
        case .positive:
            return Color(red: 0.09, green: 0.41, blue: 0.28)
        case .warning:
            return Color(red: 0.55, green: 0.30, blue: 0.00)
        case .critical:
            return Color(red: 0.61, green: 0.20, blue: 0.16)
        }
    }

    static func chipBackground(for tone: FluxTone) -> Color {
        switch tone {
        case .neutral:
            return .white.opacity(0.82)
        case .accent:
            return accentTop.opacity(0.12)
        case .positive:
            return good.opacity(0.12)
        case .warning:
            return warning.opacity(0.12)
        case .critical:
            return critical.opacity(0.12)
        }
    }

    static func chipBorder(for tone: FluxTone) -> Color {
        switch tone {
        case .neutral:
            return .white.opacity(0.80)
        case .accent:
            return accentTop.opacity(0.22)
        case .positive:
            return good.opacity(0.22)
        case .warning:
            return warning.opacity(0.22)
        case .critical:
            return critical.opacity(0.22)
        }
    }
}
