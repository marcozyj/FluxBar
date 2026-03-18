import Foundation

actor TUNManager {
    static let shared = TUNManager()

    private var lastSnapshot = TUNStatusSnapshot.placeholder

    init(fileManager: FileManager = .default) {}

    func currentStatus() -> TUNStatusSnapshot {
        lastSnapshot
    }

    func beginSwitching(to enabled: Bool) -> TUNStatusSnapshot {
        let helperInstalled = PrivilegedTUNHelperService.isInstalled()
        if enabled, helperInstalled == false {
            let requiresSetup = TUNStatusSnapshot(
                phase: .requiresSetup,
                isEnabled: false,
                permissionState: .requiresManualSetup,
                implementationTitle: "mihomo 内置 TUN / helper service",
                statusMessage: "未安装 helper/service，无法启用 TUN",
                detailMessage: "请先在设置中手动安装 TUN helper/service，然后再启用 TUN。",
                recoveryMessage: "完成安装后重试。",
                needsManualSetup: true
            )
            return recordSnapshot(requiresSetup)
        }

        let snapshot = TUNStatusSnapshot(
            phase: enabled ? .connecting : .disconnecting,
            isEnabled: enabled,
            permissionState: helperInstalled ? .ready : .permissionRequired,
            implementationTitle: "mihomo 内置 TUN / helper service",
            statusMessage: enabled ? "TUN 切换中" : "正在关闭 TUN",
            detailMessage: enabled ? "正在切换到 TUN 运行模式。" : "正在切换回非 TUN 运行模式。",
            recoveryMessage: nil,
            needsManualSetup: false
        )
        return recordSnapshot(snapshot)
    }

    func setExternalStatus(_ snapshot: TUNStatusSnapshot) -> TUNStatusSnapshot {
        recordSnapshot(snapshot)
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
                ? "已写入 TUN 配置并准备切换到 TUN 运行模式"
                : "已关闭 TUN 配置"
        )

        return recordSnapshot(snapshot)
    }

    private func makeStatusSnapshot(
        enabled: Bool,
        kernelStatus: KernelStatusSnapshot,
        runtimeTUN: RuntimeTUNSnapshot
    ) -> TUNStatusSnapshot {
        let helperInstalled = PrivilegedTUNHelperService.isInstalled()
        let implementationTitle = "mihomo 内置 TUN / helper service"

        if enabled, helperInstalled == false {
            return TUNStatusSnapshot(
                phase: .requiresSetup,
                isEnabled: false,
                permissionState: .requiresManualSetup,
                implementationTitle: implementationTitle,
                statusMessage: "TUN 未启用（helper/service 未安装）",
                detailMessage: "当前策略为严格手动安装。请先安装 helper/service，再启用 TUN。",
                recoveryMessage: "在设置页执行 helper/service 安装后重试。",
                needsManualSetup: true
            )
        }

        if enabled, kernelStatus.phase == .running {
            return TUNStatusSnapshot(
                phase: .running,
                isEnabled: true,
                permissionState: .ready,
                implementationTitle: implementationTitle,
                statusMessage: "TUN 运行中",
                detailMessage: "当前使用 \(runtimeTUN.stack ?? "system") 栈，dns-hijack \(runtimeTUN.dnsHijackCount) 项。",
                recoveryMessage: nil,
                needsManualSetup: false
            )
        }

        if enabled, kernelStatus.phase == .failed {
            let message = kernelStatus.message ?? "TUN 启动失败"
            let permissionState: TUNPermissionState = message.localizedCaseInsensitiveContains("operation not permitted")
                ? .permissionRequired
                : (helperInstalled ? .ready : .permissionRequired)
            return TUNStatusSnapshot(
                phase: .failed,
                isEnabled: true,
                permissionState: permissionState,
                implementationTitle: implementationTitle,
                statusMessage: "TUN 启动失败",
                detailMessage: message,
                recoveryMessage: helperInstalled
                    ? "请检查 helper/service、系统权限和 TUN 相关端口占用。"
                    : "请先安装 helper/service，并确认管理员授权成功。",
                needsManualSetup: false
            )
        }

        if enabled {
            return TUNStatusSnapshot(
                phase: .configuring,
                isEnabled: true,
                permissionState: helperInstalled ? .ready : .permissionRequired,
                implementationTitle: implementationTitle,
                statusMessage: "TUN 已启用，等待内核进入 TUN 模式",
                detailMessage: "配置已经写入，等待内核完成 TUN 模式启动。",
                recoveryMessage: "如长时间未进入运行态，请检查内核错误日志。",
                needsManualSetup: false
            )
        }

        return TUNStatusSnapshot(
            phase: .disabled,
            isEnabled: false,
            permissionState: helperInstalled ? .ready : .requiresManualSetup,
            implementationTitle: implementationTitle,
            statusMessage: helperInstalled ? "TUN 已关闭" : "TUN 已关闭，helper/service 未安装",
            detailMessage: helperInstalled ? "当前不会接管系统流量。" : "当前不会接管系统流量；启用前需先手动安装 helper/service。",
            needsManualSetup: helperInstalled == false
        )
    }

    @discardableResult
    private func recordSnapshot(_ snapshot: TUNStatusSnapshot) -> TUNStatusSnapshot {
        lastSnapshot = snapshot
        return snapshot
    }
}
