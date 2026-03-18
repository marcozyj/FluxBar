import Foundation

enum FluxBarRuntimeCoordinatorError: LocalizedError {
    case unsupportedKernelForTUN(KernelType)
    case missingConfigurationSource
    case helperServiceRequired
    case runtimeControllerUnavailable
    case runtimeTunStateMismatch(expected: Bool, actual: Bool?)

    var errorDescription: String? {
        switch self {
        case .unsupportedKernelForTUN(let kernel):
            return "当前只有 mihomo 支持 TUN 应用链路，\(kernel.displayName) 仍处于预留状态"
        case .missingConfigurationSource:
            return "没有找到可重建的配置来源，请先导入订阅，或把 YAML 放到 Resources/config"
        case .helperServiceRequired:
            return "未安装 TUN helper/service，请先在设置页手动安装后再启用 TUN"
        case .runtimeControllerUnavailable:
            return "Controller 不可达，无法进行运行时 TUN 切换"
        case .runtimeTunStateMismatch(let expected, let actual):
            let actualText = actual.map { $0 ? "true" : "false" } ?? "unknown"
            return "运行时 TUN 状态校验失败（期望 \(expected ? "true" : "false")，实际 \(actualText)）"
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

    private let tunModeSwitchRetryCount = 3
    private let tunModeSwitchRetryDelayNanoseconds: UInt64 = 900_000_000
    private let runtimeTunVerifyRetryCount = 32
    private let runtimeTunVerifyDelayNanoseconds: UInt64 = 250_000_000

    func applyTUNChange(
        enabled: Bool,
        selectedKernel: KernelType,
        currentConfigurationURL: URL?
    ) async throws -> FluxBarRuntimeTUNApplyResult {
        if enabled, PrivilegedTUNHelperService.isInstalled() == false {
            throw FluxBarRuntimeCoordinatorError.helperServiceRequired
        }

        let targetKernel: KernelType = .mihomo

        if selectedKernel != .mihomo {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: "请求对 \(selectedKernel.displayName) 应用 TUN，已自动切换为 mihomo。"
            )
        }

        guard let fallbackConfigurationURL = currentConfigurationURL ?? FluxBarDefaultConfigurationLocator.locate() else {
            throw FluxBarRuntimeCoordinatorError.missingConfigurationSource
        }
        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: fallbackConfigurationURL)
        let configResult = try await buildTunConfiguration(
            enabled: enabled,
            kernel: targetKernel,
            fallbackConfigurationURL: fallbackConfigurationURL,
            runtimeConfiguration: runtimeConfiguration
        )

        let runningStatus = await KernelManager.shared.runningStatus(for: targetKernel)
        let kernelHasActiveProcess = await KernelManager.shared.hasActiveKernelProcess(for: targetKernel)
        let canHotSwitchRuntime = kernelHasActiveProcess && runningStatus.phase == .running
        let isPrivilegedRuntime = await KernelManager.shared.isRunningInPrivilegedMode(for: targetKernel)

        do {
            let finalKernelStatus: KernelStatusSnapshot
            let actionMessage: String

            if canHotSwitchRuntime && (enabled == false || isPrivilegedRuntime) {
                try await applyRuntimeTunHotSwitch(
                    enabled: enabled,
                    runtimeConfiguration: runtimeConfiguration,
                    runningConfigurationURL: runningStatus.configurationURL,
                    fallbackConfigurationURL: fallbackConfigurationURL,
                    persistedConfigurationURL: configResult.outputURL
                )
                finalKernelStatus = await KernelManager.shared.runningStatus(for: targetKernel)
                actionMessage = "已\(enabled ? "启用" : "关闭") TUN（运行时热切换）"
            } else {
                let shouldStartKernel = kernelHasActiveProcess || enabled
                if shouldStartKernel {
                    if kernelHasActiveProcess {
                        let stopSnapshot = await KernelManager.shared.stop()
                        if stopSnapshot.phase == .failed {
                            throw KernelError.launchFailed(targetKernel, underlying: stopSnapshot.message ?? "停止内核失败")
                        }
                    }

                    finalKernelStatus = try await restartKernelForModeSwitch(
                        kernel: targetKernel,
                        configurationURL: configResult.outputURL,
                        controllerAddress: configResult.externalController,
                        secret: configResult.secret,
                        isDisablingTUN: enabled == false
                    )
                    guard finalKernelStatus.phase == .running else {
                        throw KernelError.launchFailed(targetKernel, underlying: finalKernelStatus.message ?? "内核未恢复到运行中")
                    }
                    actionMessage = enabled && isPrivilegedRuntime == false
                        ? "已启用 TUN，并切换到管理员模式内核"
                        : "已\(enabled ? "启用" : "关闭") TUN，并重启 \(targetKernel.displayName)"
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
                    actionMessage = "已更新 TUN 配置，\(targetKernel.displayName) 当前未运行"
                }
            }

            let tunStatus = await TUNManager.shared.refreshStatus()
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
        } catch {
            if canHotSwitchRuntime {
                _ = try? await buildTunConfiguration(
                    enabled: runtimeConfiguration.tun.enabled,
                    kernel: targetKernel,
                    fallbackConfigurationURL: fallbackConfigurationURL,
                    runtimeConfiguration: runtimeConfiguration
                )
            }
            throw error
        }
    }

    private func restartKernelForModeSwitch(
        kernel: KernelType,
        configurationURL: URL,
        controllerAddress: String?,
        secret: String?,
        isDisablingTUN: Bool
    ) async throws -> KernelStatusSnapshot {
        var lastError: Error?
        let maxRetryCount = isDisablingTUN ? 8 : tunModeSwitchRetryCount
        let retryDelayNanoseconds: UInt64 = isDisablingTUN ? 1_200_000_000 : tunModeSwitchRetryDelayNanoseconds

        for attempt in 0..<maxRetryCount {
            do {
                return try await KernelManager.shared.start(
                    KernelStartRequest(
                        kernel: kernel,
                        configurationURL: configurationURL,
                        workingDirectoryURL: configurationURL.deletingLastPathComponent(),
                        controllerAddress: controllerAddress,
                        secret: secret
                    )
                )
            } catch {
                lastError = error

                let errorMessage = error.localizedDescription
                let shouldRetry = isDisablingTUN && (
                    errorMessage.localizedCaseInsensitiveContains("端口占用")
                    || errorMessage.localizedCaseInsensitiveContains("address already in use")
                    || errorMessage.localizedCaseInsensitiveContains("controller 不可达")
                )

                if shouldRetry == false || attempt == maxRetryCount - 1 {
                    break
                }

                if isDisablingTUN {
                    _ = await KernelManager.shared.stop()
                }

                await FluxBarLogService.shared.record(
                    source: .app,
                    level: .warning,
                    message: "TUN 关闭后回切普通内核时端口仍在释放中，准备重试 (\(attempt + 1)/\(maxRetryCount - 1))：\(errorMessage)"
                )
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        throw lastError ?? KernelError.launchFailed(kernel, underlying: "内核重启失败")
    }

    private func buildTunConfiguration(
        enabled: Bool,
        kernel: KernelType,
        fallbackConfigurationURL: URL,
        runtimeConfiguration: RuntimeConfigurationSnapshot
    ) async throws -> ConfigBuildResult {
        let tunStack = runtimeConfiguration.tun.stack.flatMap(ConfigTUNStack.init(rawValue:)) ?? .system
        let dnsHijackValues = runtimeConfiguration.tun.dnsHijackValues
        let normalizedDNSHijack = enabled
            ? (dnsHijackValues.isEmpty ? ["any:53"] : dnsHijackValues)
            : dnsHijackValues

        return try await configBuilder.buildConfiguration(
            ConfigBuildRequest(
                kernel: kernel,
                fallbackConfigurationURL: fallbackConfigurationURL,
                preferredFileName: preferredConfigFileName(from: fallbackConfigurationURL),
                overrides: ConfigBuildOverrides(
                    tunEnabled: enabled,
                    tun: ConfigTUNOverrides(
                        enabled: enabled,
                        stack: tunStack,
                        autoRoute: runtimeConfiguration.tun.autoRoute ?? true,
                        autoDetectInterface: runtimeConfiguration.tun.autoDetectInterface ?? true,
                        strictRoute: runtimeConfiguration.tun.strictRoute ?? false,
                        dnsHijack: normalizedDNSHijack
                    )
                )
            )
        )
    }

    private func preferredConfigFileName(from fallbackConfigurationURL: URL) -> String {
        let fileName = fallbackConfigurationURL.lastPathComponent
        if FluxBarConfigCleanupService.isManagedGeneratedYAMLFileName(fileName.lowercased()) {
            return "FluxBar.yaml"
        }
        return fileName
    }

    private func applyRuntimeTunHotSwitch(
        enabled: Bool,
        runtimeConfiguration: RuntimeConfigurationSnapshot,
        runningConfigurationURL: URL?,
        fallbackConfigurationURL: URL?,
        persistedConfigurationURL: URL
    ) async throws {
        let context = [
            runningConfigurationURL,
            fallbackConfigurationURL,
            persistedConfigurationURL
        ]
            .compactMap { $0 }
            .compactMap { FluxBarConfigurationSupport.controllerContext(from: $0) }
            .first

        guard let context else {
            throw FluxBarRuntimeCoordinatorError.runtimeControllerUnavailable
        }

        let dnsHijackValues = runtimeConfiguration.tun.dnsHijackValues
        let client = MihomoControllerClient(configuration: context.configuration)
        try await client.patchTunConfiguration(
            enabled: enabled,
            stack: enabled ? (runtimeConfiguration.tun.stack ?? ConfigTUNStack.system.rawValue) : runtimeConfiguration.tun.stack,
            autoRoute: runtimeConfiguration.tun.autoRoute ?? true,
            autoDetectInterface: runtimeConfiguration.tun.autoDetectInterface ?? true,
            strictRoute: runtimeConfiguration.tun.strictRoute ?? false,
            dnsHijack: enabled ? (dnsHijackValues.isEmpty ? ["any:53"] : dnsHijackValues) : dnsHijackValues,
            enableDNS: enabled ? true : nil
        )

        var lastObserved: Bool?
        for _ in 0..<runtimeTunVerifyRetryCount {
            do {
                let observed = try await client.fetchRuntimeTunEnabled()
                lastObserved = observed

                if observed == enabled {
                    return
                }
            } catch {
                // Runtime may briefly reject requests during state transition.
            }
            try? await Task.sleep(nanoseconds: runtimeTunVerifyDelayNanoseconds)
        }

        throw FluxBarRuntimeCoordinatorError.runtimeTunStateMismatch(expected: enabled, actual: lastObserved)
    }
}
