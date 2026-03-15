import Foundation

enum FluxBarRuntimeCoordinatorError: LocalizedError {
    case unsupportedKernelForTUN(KernelType)
    case missingConfigurationSource

    var errorDescription: String? {
        switch self {
        case .unsupportedKernelForTUN(let kernel):
            return "当前只有 mihomo 支持 TUN 应用链路，\(kernel.displayName) 仍处于预留状态"
        case .missingConfigurationSource:
            return "没有找到可重建的配置来源，请先导入订阅，或把 YAML 放到 Resources/config"
        }
    }
}

struct FluxBarRuntimeTUNApplyResult {
    let kernel: KernelType
    let kernelStatus: KernelStatusSnapshot
    let configResult: ConfigBuildResult
    let tunStatus: TUNStatusSnapshot
    let message: String
}

actor FluxBarRuntimeCoordinator {
    static let shared = FluxBarRuntimeCoordinator()

    private let configBuilder: ConfigBuilder

    init(configBuilder: ConfigBuilder = .shared) {
        self.configBuilder = configBuilder
    }

    func applyTUNChange(
        enabled: Bool,
        selectedKernel: KernelType,
        currentConfigurationURL: URL?
    ) async throws -> FluxBarRuntimeTUNApplyResult {
        let targetKernel: KernelType = .mihomo

        if selectedKernel != .mihomo {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: "请求对 \(selectedKernel.displayName) 应用 TUN，已自动切换为 mihomo。"
            )
        }

        let fallbackConfigurationURL = currentConfigurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        guard fallbackConfigurationURL != nil else {
            throw FluxBarRuntimeCoordinatorError.missingConfigurationSource
        }

        let configResult = try await configBuilder.buildConfiguration(
            ConfigBuildRequest(
                kernel: targetKernel,
                fallbackConfigurationURL: fallbackConfigurationURL,
                preferredFileName: "fluxbar-\(targetKernel.rawValue)-runtime.yaml",
                overrides: ConfigBuildOverrides(
                    tunEnabled: enabled,
                    tun: ConfigTUNOverrides(
                        enabled: enabled,
                        stack: .system,
                        autoRoute: true,
                        autoDetectInterface: true,
                        strictRoute: false,
                        dnsHijack: enabled ? ["any:53"] : nil
                    )
                )
            )
        )

        let runningStatus = await KernelManager.shared.runningStatus(for: targetKernel)
        let shouldStartKernel = runningStatus.isRunning || enabled

        let finalKernelStatus: KernelStatusSnapshot
        if shouldStartKernel {
            if runningStatus.isRunning {
                _ = await KernelManager.shared.stop()
            }

            finalKernelStatus = try await KernelManager.shared.start(
                KernelStartRequest(
                    kernel: targetKernel,
                    configurationURL: configResult.outputURL,
                    workingDirectoryURL: configResult.outputURL.deletingLastPathComponent(),
                    controllerAddress: configResult.externalController,
                    secret: configResult.secret
                )
            )
        } else {
            finalKernelStatus = KernelStatusSnapshot(
                kernel: targetKernel,
                phase: .stopped,
                processIdentifier: nil,
                binaryURL: nil,
                configurationURL: configResult.outputURL,
                launchedAt: nil,
                lastExitCode: runningStatus.lastExitCode,
                message: "已重建配置，内核当前未运行"
            )
        }

        let tunStatus = await TUNManager.shared.setEnabled(enabled)
        let actionMessage = shouldStartKernel
            ? "已\(enabled ? "启用" : "关闭") TUN，并重启 \(targetKernel.displayName)"
            : "已更新 TUN 配置，\(targetKernel.displayName) 当前未运行"

        await FluxBarLogService.shared.record(
            source: .app,
            level: .info,
            message: "\(actionMessage)，配置文件：\(configResult.outputURL.lastPathComponent)"
        )

        return FluxBarRuntimeTUNApplyResult(
            kernel: targetKernel,
            kernelStatus: finalKernelStatus,
            configResult: configResult,
            tunStatus: tunStatus,
            message: actionMessage
        )
    }
}
