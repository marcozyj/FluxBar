import Foundation

struct RuntimeControllerSnapshot: Sendable {
    let bindAddress: String?
    let accessAddress: String?
    let secretValue: String?
    let panelURL: URL?
    let secretConfigured: Bool
    let exposesExternally: Bool
    let statusMessage: String

    nonisolated static let unavailable = RuntimeControllerSnapshot(
        bindAddress: nil,
        accessAddress: nil,
        secretValue: nil,
        panelURL: nil,
        secretConfigured: false,
        exposesExternally: false,
        statusMessage: "Controller 未配置"
    )
}

struct RuntimeTUNSnapshot: Sendable {
    let enabled: Bool
    let stack: String?
    let autoRoute: Bool?
    let autoDetectInterface: Bool?
    let dnsHijackCount: Int
    let statusMessage: String

    nonisolated static let unavailable = RuntimeTUNSnapshot(
        enabled: false,
        stack: nil,
        autoRoute: nil,
        autoDetectInterface: nil,
        dnsHijackCount: 0,
        statusMessage: "TUN 未配置"
    )
}

struct RuntimeConfigurationSnapshot: Sendable {
    let controller: RuntimeControllerSnapshot
    let modeTitle: String?
    let tun: RuntimeTUNSnapshot

    nonisolated static let unavailable = RuntimeConfigurationSnapshot(
        controller: .unavailable,
        modeTitle: nil,
        tun: .unavailable
    )
}
