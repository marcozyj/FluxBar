import Foundation

actor TUNManager {
    static let shared = TUNManager()

    private var lastSnapshot = TUNStatusSnapshot.placeholder

    init(fileManager: FileManager = .default) {}

    func currentStatus() -> TUNStatusSnapshot {
        lastSnapshot
    }

    func refreshStatus() async -> TUNStatusSnapshot {
        let kernelStatus = await KernelManager.shared.runningStatus()
        let configurationURL = kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL)
        let snapshot = makeStatusSnapshot(
            enabled: runtimeConfiguration.tun.enabled,
            kernelStatus: kernelStatus,
            runtimeTUN: runtimeConfiguration.tun
        )
        return recordSnapshot(snapshot)
    }

    func setEnabled(_ enabled: Bool) async -> TUNStatusSnapshot {
        let kernelStatus = await KernelManager.shared.runningStatus()
        let snapshot = makeStatusSnapshot(
            enabled: enabled,
            kernelStatus: kernelStatus,
            runtimeTUN: RuntimeConfigurationSnapshot.unavailable.tun
        )

        await FluxBarLogService.shared.record(
            source: .tun,
            level: .info,
            message: enabled
                ? "已写入 TUN 配置并准备接管 mihomo 内核启动链路"
                : "已关闭 TUN 配置"
        )

        return recordSnapshot(snapshot)
    }

    private func makeStatusSnapshot(
        enabled: Bool,
        kernelStatus: KernelStatusSnapshot,
        runtimeTUN: RuntimeTUNSnapshot
    ) -> TUNStatusSnapshot {
        if enabled, kernelStatus.isRunning {
            return TUNStatusSnapshot(
                phase: .running,
                isEnabled: true,
                permissionState: .ready,
                implementationTitle: "mihomo 内置 TUN",
                statusMessage: "TUN 运行中",
                detailMessage: "当前使用 \(runtimeTUN.stack ?? "system") 栈，dns-hijack \(runtimeTUN.dnsHijackCount) 项。",
                recoveryMessage: nil,
                needsManualSetup: false
            )
        }

        if enabled {
            return TUNStatusSnapshot(
                phase: .configuring,
                isEnabled: true,
                permissionState: .unknown,
                implementationTitle: "mihomo 内置 TUN",
                statusMessage: "TUN 已启用，等待内核启动",
                detailMessage: "配置已经写入，启动内核后即可接管流量。",
                recoveryMessage: "如系统栈启动失败，请以具备所需权限的方式运行内核。",
                needsManualSetup: false
            )
        }

        return TUNStatusSnapshot(
            phase: .disabled,
            isEnabled: false,
            permissionState: .ready,
            implementationTitle: "mihomo 内置 TUN",
            statusMessage: "TUN 已关闭",
            detailMessage: "当前不会接管系统流量。",
            needsManualSetup: false
        )
    }

    @discardableResult
    private func recordSnapshot(_ snapshot: TUNStatusSnapshot) -> TUNStatusSnapshot {
        lastSnapshot = snapshot
        return snapshot
    }
}
