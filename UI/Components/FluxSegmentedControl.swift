import SwiftUI

struct FluxSegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: AnyHashable { AnyHashable(value) }
}

enum FluxSegmentedControlAppearance {
    case tabBar
    case compact
}

struct FluxSegmentedControl<Value: Hashable>: View {
    let options: [FluxSegmentedOption<Value>]
    @Binding var selection: Value
    var appearance: FluxSegmentedControlAppearance = .compact

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        selection = option.value
                    }
                } label: {
                    ZStack {
                        segmentBackground(isSelected: option.value == selection)

                        Text(option.title)
                            .font(.system(size: fontSize, weight: .heavy))
                            .foregroundStyle(foregroundColor(isSelected: option.value == selection))
                    }
                    .frame(maxWidth: .infinity, minHeight: segmentHeight, maxHeight: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: segmentHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(containerPadding)
        .background(
            RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                .fill(containerFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.84), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.20, green: 0.27, blue: 0.40).opacity(0.08), radius: 10, y: 4)
    }

    private var containerCornerRadius: CGFloat {
        switch appearance {
        case .tabBar:
            return 16
        case .compact:
            return 18
        }
    }

    private var containerPadding: CGFloat {
        switch appearance {
        case .tabBar:
            return 6
        case .compact:
            return 6
        }
    }

    private var segmentHeight: CGFloat {
        switch appearance {
        case .tabBar:
            return 44
        case .compact:
            return 40
        }
    }

    private var fontSize: CGFloat {
        switch appearance {
        case .tabBar:
            return 14
        case .compact:
            return 13
        }
    }

    private var segmentCornerRadius: CGFloat {
        switch appearance {
        case .tabBar:
            return 12
        case .compact:
            return 14
        }
    }

    private var containerFill: Color {
        switch appearance {
        case .tabBar:
            return Color.white.opacity(0.90)
        case .compact:
            return .white.opacity(0.88)
        }
    }

    private func foregroundColor(isSelected: Bool) -> Color {
        switch appearance {
        case .tabBar:
            return isSelected ? .white : FluxTheme.textTertiary
        case .compact:
            return isSelected ? Color(red: 0.08, green: 0.20, blue: 0.37) : Color(red: 0.24, green: 0.31, blue: 0.42)
        }
    }

    @ViewBuilder
    private func segmentBackground(isSelected: Bool) -> some View {
        switch appearance {
        case .tabBar:
            RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(FluxTheme.accentFill) : AnyShapeStyle(Color.clear))
                .shadow(color: isSelected ? FluxTheme.accentTop.opacity(0.28) : .clear, radius: 10, y: 6)
        case .compact:
            RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous)
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.80, green: 0.89, blue: 1.0).opacity(0.94),
                                    Color(red: 0.71, green: 0.84, blue: 1.0).opacity(0.88)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(
                            FluxTheme.elevatedFill
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.78) : Color.white.opacity(0.92), lineWidth: 1)
                )
                .shadow(color: isSelected ? Color(red: 0.22, green: 0.49, blue: 1.0).opacity(0.14) : Color.black.opacity(0.07), radius: 8, y: 4)
        }
    }
}
