import Foundation

enum FluxBarTab: String, CaseIterable, Identifiable {
    case nodes
    case strategy
    case routing
    case network
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .nodes:
            "节点"
        case .strategy:
            "策略"
        case .routing:
            "分流"
        case .network:
            "网络"
        case .settings:
            "设置"
        }
    }
}
