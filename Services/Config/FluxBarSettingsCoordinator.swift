import Foundation

enum FluxBarSettingsCoordinatorError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "没有找到可应用设置的配置文件"
        }
    }
}

actor FluxBarSettingsCoordinator {
    static let shared = FluxBarSettingsCoordinator()

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

        let result = try await ConfigBuilder.shared.buildConfiguration(
            ConfigBuildRequest(
                kernel: .mihomo,
                fallbackConfigurationURL: sourceURL,
                preferredFileName: sourceURL.lastPathComponent,
                overrides: ConfigBuildOverrides(
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
                        dnsHijack: runtimeConfiguration.tun.dnsHijackCount > 0 ? ["any:53"] : nil
                    )
                )
            )
        )

        if await KernelManager.shared.runningStatus(for: .mihomo).isRunning {
            _ = try? await FluxBarKernelLifecycleController.shared.startOrRestartSelectedKernel(forceRestart: true)
        }

        _ = RoutingRulesCacheStore.refresh(configurationURL: result.outputURL)

        await MainActor.run {
            NotificationCenter.default.post(name: fluxBarConfigurationDidRefreshNotification, object: nil)
        }

        return result
    }

    private func parsePort(_ value: String?) -> Int? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }

        return Int(trimmed)
    }
}
