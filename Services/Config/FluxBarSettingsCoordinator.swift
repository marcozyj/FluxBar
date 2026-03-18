import Foundation

enum FluxBarSettingsCoordinatorError: LocalizedError {
    case missingConfiguration
    case invalidExternalControllerAddress
    case missingExternalControllerSecret

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "没有找到可应用设置的配置文件"
        case .invalidExternalControllerAddress:
            return "外部控制地址不能为空"
        case .missingExternalControllerSecret:
            return "启用外部控制时必须填写 secret"
        }
    }
}

struct FluxBarAdvancedSettingsInput: Sendable {
    let tunEnabled: Bool
    let tunStack: ConfigTUNStack
    let tunAutoRoute: Bool
    let tunAutoDetectInterface: Bool
    let tunStrictRoute: Bool
    let tunDNSHijack: [String]
    let externalControllerEnabled: Bool
    let externalControllerAddress: String
    let externalControllerSecret: String
    let externalControllerAllowPrivateNetwork: Bool
    let externalControllerAllowOrigins: [String]
}

actor FluxBarSettingsCoordinator {
    static let shared = FluxBarSettingsCoordinator()
    private let localControllerAddress = "127.0.0.1:19090"

    private struct SettingsApplyFlags: Sendable {
        let restartKernelIfRunning: Bool
        let reapplySystemProxyIfEnabled: Bool
    }

    func applyCoreSettings(
        allowLAN: Bool,
        ipv6: Bool,
        ports: [String: String]
    ) async throws -> ConfigBuildResult {
        guard let sourceURL = FluxBarDefaultConfigurationLocator.locate() else {
            throw FluxBarSettingsCoordinatorError.missingConfiguration
        }

        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: sourceURL)
        let tunStack = runtimeConfiguration.tun.stack.flatMap(ConfigTUNStack.init(rawValue:))

        let overrides = ConfigBuildOverrides(
            httpPort: parsePort(ports["http"]),
            socksPort: parsePort(ports["socks"]),
            mixedPort: parsePort(ports["mixed"]),
            redirPort: parsePort(ports["redir"]),
            tproxyPort: parsePort(ports["tproxy"]),
            allowLAN: allowLAN,
            ipv6: ipv6,
            tunEnabled: runtimeConfiguration.tun.enabled,
            tun: ConfigTUNOverrides(
                enabled: runtimeConfiguration.tun.enabled,
                stack: tunStack,
                autoRoute: runtimeConfiguration.tun.autoRoute,
                autoDetectInterface: runtimeConfiguration.tun.autoDetectInterface,
                strictRoute: runtimeConfiguration.tun.strictRoute,
                dnsHijack: runtimeConfiguration.tun.dnsHijackValues.isEmpty
                    ? nil
                    : runtimeConfiguration.tun.dnsHijackValues
            )
        )

        return try await applyConfiguration(
            sourceURL: sourceURL,
            overrides: overrides,
            flags: SettingsApplyFlags(
                restartKernelIfRunning: true,
                reapplySystemProxyIfEnabled: true
            )
        )
    }

    private func parsePort(_ value: String?) -> Int? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }

        return Int(trimmed)
    }

    func applyAdvancedSettings(_ input: FluxBarAdvancedSettingsInput) async throws -> ConfigBuildResult {
        guard let sourceURL = FluxBarDefaultConfigurationLocator.locate() else {
            throw FluxBarSettingsCoordinatorError.missingConfiguration
        }

        let normalizedAddress = input.externalControllerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecret = input.externalControllerSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.externalControllerEnabled {
            if normalizedAddress.isEmpty {
                throw FluxBarSettingsCoordinatorError.invalidExternalControllerAddress
            }

            if normalizedSecret.isEmpty {
                throw FluxBarSettingsCoordinatorError.missingExternalControllerSecret
            }
        }

        let overrides = ConfigBuildOverrides(
            externalControllerEnabled: input.externalControllerEnabled,
            externalController: input.externalControllerEnabled ? normalizedAddress : localControllerAddress,
            secret: input.externalControllerEnabled ? normalizedSecret : nil,
            externalControllerCORS: ConfigExternalControllerCORSOverrides(
                allowPrivateNetwork: input.externalControllerAllowPrivateNetwork,
                allowOrigins: input.externalControllerAllowOrigins
            ),
            tunEnabled: input.tunEnabled,
            tun: ConfigTUNOverrides(
                enabled: input.tunEnabled,
                stack: input.tunStack,
                autoRoute: input.tunAutoRoute,
                autoDetectInterface: input.tunAutoDetectInterface,
                strictRoute: input.tunStrictRoute,
                dnsHijack: input.tunDNSHijack
            )
        )

        return try await applyConfiguration(
            sourceURL: sourceURL,
            overrides: overrides,
            flags: SettingsApplyFlags(
                restartKernelIfRunning: true,
                reapplySystemProxyIfEnabled: true
            )
        )
    }

    private func applyConfiguration(
        sourceURL: URL,
        overrides: ConfigBuildOverrides,
        flags: SettingsApplyFlags
    ) async throws -> ConfigBuildResult {
        let backupText = try? String(contentsOf: sourceURL, encoding: .utf8)
        let request = ConfigBuildRequest(
            kernel: .mihomo,
            fallbackConfigurationURL: sourceURL,
            preferredFileName: sourceURL.lastPathComponent,
            overrides: overrides
        )
        let result = try await ConfigBuilder.shared.buildConfiguration(request)

        do {
            if flags.restartKernelIfRunning, await KernelManager.shared.runningStatus(for: .mihomo).isRunning {
                _ = try await FluxBarKernelLifecycleController.shared.startOrRestartSelectedKernel(forceRestart: true)
            }

            _ = RoutingRulesCacheStore.refresh(configurationURL: result.outputURL)

            if flags.reapplySystemProxyIfEnabled, FluxBarPreferences.bool(for: "settings.systemProxyEnabled", fallback: false) {
                _ = await SystemProxyManager.shared.applyProxyState(enabled: true, configurationURL: result.outputURL)
            }

            await MainActor.run {
                NotificationCenter.default.post(name: fluxBarConfigurationDidRefreshNotification, object: nil)
            }

            return result
        } catch {
            if let backupText {
                try? backupText.write(to: result.outputURL, atomically: true, encoding: .utf8)
                _ = RoutingRulesCacheStore.refresh(configurationURL: result.outputURL)
                await FluxBarLogService.shared.record(
                    source: .app,
                    level: .warning,
                    message: "设置应用失败，已回滚配置：\(error.localizedDescription)"
                )
            }

            throw error
        }
    }
}
