import Foundation

enum FluxBarKernelLifecycleError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "没有找到可用配置文件，无法启动内核"
        }
    }
}

actor FluxBarKernelLifecycleController {
    static let shared = FluxBarKernelLifecycleController()

    private var didRunLaunchBootstrap = false
    private let configBuilder: ConfigBuilder

    init(configBuilder: ConfigBuilder = .shared) {
        self.configBuilder = configBuilder
    }

    func bootstrapOnLaunchIfNeeded() async {
        guard didRunLaunchBootstrap == false else {
            return
        }

        didRunLaunchBootstrap = true
        _ = await KernelManager.shared.selectKernel(FluxBarPreferences.selectedKernel)

        guard FluxBarPreferences.coreAutoStartEnabled else {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "内核自启已关闭，跳过启动时自动拉起内核"
            )
            return
        }

        do {
            _ = try await startOrRestartSelectedKernel(forceRestart: false)
            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "应用启动完成，已自动拉起 \(FluxBarPreferences.selectedKernel.displayName) 内核"
            )
        } catch {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .error,
                message: "应用启动时自动拉起内核失败：\(error.localizedDescription)"
            )
        }
    }

    func startOrRestartSelectedKernel(forceRestart: Bool) async throws -> KernelStatusSnapshot {
        let kernel = FluxBarPreferences.selectedKernel
        _ = await KernelManager.shared.selectKernel(kernel)

        guard let configurationURL = FluxBarDefaultConfigurationLocator.locate() else {
            throw FluxBarKernelLifecycleError.missingConfiguration
        }

        let currentStatus = await KernelManager.shared.runningStatus(for: kernel)
        if forceRestart == false, currentStatus.isRunning {
            return currentStatus
        }

        if currentStatus.isRunning {
            _ = await KernelManager.shared.stop()
        }

        let launchConfigurationURL = currentStatus.configurationURL ?? configurationURL
        let request = KernelStartRequest(
            kernel: kernel,
            configurationURL: launchConfigurationURL,
            workingDirectoryURL: launchConfigurationURL.deletingLastPathComponent()
        )

        do {
            return try await KernelManager.shared.start(request)
        } catch {
            guard kernel == .mihomo else {
                throw error
            }

            let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: launchConfigurationURL)
            guard runtimeConfiguration.tun.enabled else {
                throw error
            }

            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: "检测到 TUN 模式启动失败，准备自动回退到普通模式：\(error.localizedDescription)"
            )

            return try await recoverFromTUNStartupFailure(
                kernel: kernel,
                failedConfigurationURL: launchConfigurationURL,
                runtimeConfiguration: runtimeConfiguration
            )
        }
    }

    private func recoverFromTUNStartupFailure(
        kernel: KernelType,
        failedConfigurationURL: URL,
        runtimeConfiguration: RuntimeConfigurationSnapshot
    ) async throws -> KernelStatusSnapshot {
        let rollbackConfigResult = try await configBuilder.buildConfiguration(
            ConfigBuildRequest(
                kernel: kernel,
                fallbackConfigurationURL: failedConfigurationURL,
                preferredFileName: failedConfigurationURL.lastPathComponent,
                overrides: ConfigBuildOverrides(
                    tunEnabled: false,
                    tun: ConfigTUNOverrides(
                        enabled: false,
                        stack: runtimeConfiguration.tun.stack.flatMap(ConfigTUNStack.init(rawValue:)),
                        autoRoute: runtimeConfiguration.tun.autoRoute ?? true,
                        autoDetectInterface: runtimeConfiguration.tun.autoDetectInterface ?? true,
                        strictRoute: runtimeConfiguration.tun.strictRoute ?? false,
                        dnsHijack: runtimeConfiguration.tun.dnsHijackValues
                    )
                )
            )
        )

        let recoveringStatus = TUNStatusSnapshot(
            phase: .recovering,
            isEnabled: false,
            permissionState: PrivilegedTUNHelperService.isInstalled() ? .ready : .requiresManualSetup,
            implementationTitle: "mihomo 内置 TUN / helper service",
            statusMessage: "启动失败，已自动回退到普通模式",
            detailMessage: "检测到 TUN 模式异常，已改为非 TUN 配置并自动重启内核。",
            recoveryMessage: "内核已恢复；如需启用 TUN，请在设置中再次手动开启。",
            needsManualSetup: false
        )
        _ = await TUNManager.shared.setExternalStatus(recoveringStatus)

        let recoveredStatus = try await KernelManager.shared.start(
            KernelStartRequest(
                kernel: kernel,
                configurationURL: rollbackConfigResult.outputURL,
                workingDirectoryURL: rollbackConfigResult.outputURL.deletingLastPathComponent(),
                controllerAddress: rollbackConfigResult.externalController,
                secret: rollbackConfigResult.secret
            )
        )

        await FluxBarLogService.shared.record(
            source: .app,
            level: .warning,
            message: "TUN 启动失败已自动回退，内核已恢复运行。"
        )

        return recoveredStatus
    }
}
