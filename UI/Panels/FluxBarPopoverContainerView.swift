import SwiftUI

struct FluxBarPopoverContainerView: View {
    private static let panelWidth: CGFloat = 468
    private static let panelHeight: CGFloat = 928
    @State private var selectedTab: FluxBarTab = .nodes
    @State private var previousTab: FluxBarTab = .nodes
    @StateObject private var toastCenter = FluxToastCenter()
    @StateObject private var runtimeStore = FluxBarRuntimeStore()
    @StateObject private var dashboardSummaryStore = FluxBarDashboardSummaryStore()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.92),
                            Color.white.opacity(0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.94), lineWidth: 1)
                )
                .shadow(color: Color(red: 0.09, green: 0.18, blue: 0.34).opacity(0.10), radius: 24, y: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.60),
                                    .clear,
                                    Color.white.opacity(0.24)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

            VStack(spacing: 0) {
                FluxBarTopStatusView(runtimeStore: runtimeStore) {
                    Task {
                        do {
                            let status = try await FluxBarKernelLifecycleController.shared.startOrRestartSelectedKernel(forceRestart: true)
                            await runtimeStore.refreshNow()

                            await MainActor.run {
                                toastCenter.show(status.message ?? "已执行内核操作", tone: .accent)
                            }
                        } catch {
                            await MainActor.run {
                                toastCenter.show(error.localizedDescription, tone: .critical)
                            }
                        }
                    }
                }

                FluxBarPrimaryTabBarView(selectedTab: $selectedTab)
                    .padding(.bottom, 10)

                viewport
                footer
            }
            .padding(14)
            .fluxPanelEntrance()

            FluxToastStack(center: toastCenter)
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .task {
            runtimeStore.startSyncLoop()
            dashboardSummaryStore.startSyncLoop()
        }
        .onChange(of: selectedTab) { oldValue, _ in
            previousTab = oldValue
        }
        .onDisappear {
            runtimeStore.stopSyncLoop()
            dashboardSummaryStore.stopSyncLoop()
        }
    }

    private var viewport: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(FluxTheme.viewportFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.86), lineWidth: 1)
                )

            currentPage
                .id(selectedTab)
                .padding(12)
                .transition(FluxMotion.tabTransition(edge: tabTransitionEdge))
        }
        .frame(maxWidth: .infinity, minHeight: 760, maxHeight: 760, alignment: .topLeading)
        .shadow(color: Color.black.opacity(0.035), radius: 14, y: 5)
        .animation(FluxMotion.tabAnimation, value: selectedTab)
    }

    private var tabTransitionEdge: Edge {
        let tabs = FluxBarTab.allCases
        let oldIndex = tabs.firstIndex(of: previousTab) ?? 0
        let newIndex = tabs.firstIndex(of: selectedTab) ?? 0
        return newIndex >= oldIndex ? .trailing : .leading
    }

    private var footer: some View {
        HStack {
            Text("◉ MIHOMO v1.19.20")
            Spacer()
            Text("FluxBar v0.1.0")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(FluxTheme.textSecondary)
        .padding(.horizontal, 2)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch selectedTab {
        case .nodes:
            DashboardPageView(runtimeStore: runtimeStore, summaryStore: dashboardSummaryStore) { message in
                toastCenter.show(message, tone: .positive)
            }
        case .strategy:
            StrategyPageView { message in
                toastCenter.show(message, tone: .accent)
            }
        case .routing:
            RoutingPageView()
        case .network:
            NetworkPageView()
        case .settings:
            SettingsPageView(runtimeStore: runtimeStore) { message in
                toastCenter.show(message, tone: .accent)
            }
        }
    }
}
