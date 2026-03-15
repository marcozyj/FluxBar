import Combine
import SwiftUI

struct FluxToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let tone: FluxTone
}

@MainActor
final class FluxToastCenter: ObservableObject {
    @Published private(set) var items: [FluxToastItem] = []

    func show(_ message: String, tone: FluxTone = .neutral, duration: TimeInterval = 2.2) {
        let item = FluxToastItem(message: message, tone: tone)

        withAnimation(FluxMotion.toastAnimation) {
            items.append(item)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.dismiss(item)
        }
    }

    func dismiss(_ item: FluxToastItem) {
        guard items.contains(item) else { return }

        withAnimation(.easeInOut(duration: 0.22)) {
            items.removeAll { $0.id == item.id }
        }
    }
}

struct FluxToastStack: View {
    @ObservedObject var center: FluxToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.items) { item in
                FluxToastView(item: item)
                    .transition(FluxMotion.toastTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .allowsHitTesting(false)
    }
}

struct FluxToastView: View {
    let item: FluxToastItem

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(item.message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(
            Color(red: 0.09, green: 0.13, blue: 0.21).opacity(0.88),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    private var indicatorColor: Color {
        switch item.tone {
        case .neutral:
            return .white.opacity(0.7)
        case .accent:
            return FluxTheme.accentTop
        case .positive:
            return FluxTheme.good
        case .warning:
            return FluxTheme.warning
        case .critical:
            return FluxTheme.critical
        }
    }
}
