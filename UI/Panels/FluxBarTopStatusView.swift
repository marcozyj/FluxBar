import AppKit
import SwiftUI

struct FluxBarTopStatusView: View {
    @ObservedObject var runtimeStore: FluxBarRuntimeStore
    var onRefresh: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                logo

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("FluxBar")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(FluxTheme.textPrimary)

                        statusPill
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 12, weight: .bold))

                        externalPanelButton
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FluxTheme.textSecondary)
                }
            }

            Spacer(minLength: 8)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(FluxTheme.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.99),
                                        Color.white.opacity(0.88)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.white.opacity(0.92), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var kernelPhaseTitle: String {
        switch runtimeStore.kernelStatus.phase {
        case .running:
            return "运行中"
        case .starting:
            return "启动中"
        case .stopping:
            return "停止中"
        case .failed:
            return "异常"
        case .stopped:
            return "未运行"
        }
    }

    private var externalPanelButton: some View {
        Button {
            guard let url = externalPanelURL else {
                return
            }
            NSWorkspace.shared.open(url)
        } label: {
            Text("外部面板")
                .foregroundStyle(externalPanelURL == nil ? FluxTheme.textSecondary : FluxTheme.accentTop)
                .underline(externalPanelURL != nil, color: FluxTheme.accentTop.opacity(0.45))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(externalPanelURL == nil)
    }

    private var externalPanelURL: URL? {
        runtimeStore.controllerSnapshot.panelURL
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)

            Text(kernelPhaseTitle)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(FluxTheme.chipForeground(for: statusTone))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.white.opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.94), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 4)
    }

    private var statusTone: FluxTone {
        switch runtimeStore.kernelStatus.phase {
        case .running:
            return .positive
        case .starting, .stopping:
            return .accent
        case .failed:
            return .critical
        case .stopped:
            return .warning
        }
    }

    private var statusDotColor: Color {
        switch statusTone {
        case .neutral:
            return FluxTheme.textSecondary
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

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.17),
                            Color(red: 0.03, green: 0.04, blue: 0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    eye
                    eye
                }

                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 18, height: 4)
            }
        }
        .frame(width: 46, height: 46)
        .shadow(color: Color.black.opacity(0.16), radius: 10, y: 6)
    }

    private var eye: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)

            Circle()
                .fill(Color.black)
                .frame(width: 4, height: 4)
        }
    }
}
