import SwiftUI

struct FluxChip: View {
    let title: String
    var tone: FluxTone = .neutral
    var monospace = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .heavy, design: monospace ? .monospaced : .default))
            .foregroundStyle(FluxTheme.chipForeground(for: tone))
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(FluxTheme.chipBackground(for: tone))
            )
            .overlay(
                Capsule()
                    .stroke(FluxTheme.chipBorder(for: tone), lineWidth: 1)
            )
    }
}
