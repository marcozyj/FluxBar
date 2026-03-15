import SwiftUI

struct FluxBarPrimaryTabBarView: View {
    @Binding var selectedTab: FluxBarTab

    var body: some View {
        FluxSegmentedControl(
            options: FluxBarTab.allCases.map { FluxSegmentedOption(value: $0, title: $0.title) },
            selection: $selectedTab,
            appearance: .tabBar
        )
    }
}
