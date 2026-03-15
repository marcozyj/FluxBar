import Foundation

enum TUNPermissionState: String, Sendable {
    case unknown
    case ready
    case permissionRequired
    case requiresManualSetup
}

struct TUNStatusSnapshot: Sendable {
    enum Phase: String, Sendable {
        case disabled
        case configuring
        case connecting
        case running
        case disconnecting
        case requiresSetup
        case recovering
        case failed
    }

    let phase: Phase
    let isEnabled: Bool
    let permissionState: TUNPermissionState
    let implementationTitle: String?
    let statusMessage: String
    let detailMessage: String?
    let recoveryMessage: String?
    let needsManualSetup: Bool
    let updatedAt: Date

    nonisolated init(
        phase: Phase,
        isEnabled: Bool,
        permissionState: TUNPermissionState,
        implementationTitle: String?,
        statusMessage: String,
        detailMessage: String? = nil,
        recoveryMessage: String? = nil,
        needsManualSetup: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.isEnabled = isEnabled
        self.permissionState = permissionState
        self.implementationTitle = implementationTitle
        self.statusMessage = statusMessage
        self.detailMessage = detailMessage
        self.recoveryMessage = recoveryMessage
        self.needsManualSetup = needsManualSetup
        self.updatedAt = updatedAt
    }

    nonisolated static let placeholder = TUNStatusSnapshot(
        phase: .configuring,
        isEnabled: false,
        permissionState: .unknown,
        implementationTitle: "mihomo 内置 TUN / helper service",
        statusMessage: "正在读取 TUN 状态"
    )

    nonisolated func transitioning(to enabled: Bool) -> TUNStatusSnapshot {
        TUNStatusSnapshot(
            phase: enabled ? .connecting : .disconnecting,
            isEnabled: enabled,
            permissionState: permissionState,
            implementationTitle: implementationTitle,
            statusMessage: enabled ? "正在启用 TUN" : "正在关闭 TUN",
            detailMessage: detailMessage,
            recoveryMessage: recoveryMessage,
            needsManualSetup: needsManualSetup
        )
    }
}
