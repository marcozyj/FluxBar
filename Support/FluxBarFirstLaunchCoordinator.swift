import Foundation

actor FluxBarFirstLaunchCoordinator {
    static let shared = FluxBarFirstLaunchCoordinator()

    private var didRun = false

    func bootstrapIfNeeded() async {
        guard didRun == false else {
            return
        }

        didRun = true
        let isFirstLaunch = FluxBarPreferences.didInitializeDefaults == false
        FluxBarPreferences.initializeDefaultsIfNeeded()

        do {
            try OpenAtLoginManager.syncWithPreference()
        } catch {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: error.localizedDescription
            )
        }

        guard isFirstLaunch else {
            return
        }

        _ = await SystemProxyManager.shared.disableAllProxies()

        guard let sourceURL = FluxBarDefaultConfigurationLocator.locate() else {
            return
        }

        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: sourceURL)
        let tunStack = runtimeConfiguration.tun.stack.flatMap(ConfigTUNStack.init(rawValue:))

        do {
            let result = try await ConfigBuilder.shared.buildConfiguration(
                ConfigBuildRequest(
                    kernel: .mihomo,
                    fallbackConfigurationURL: sourceURL,
                    preferredFileName: sourceURL.lastPathComponent,
                    overrides: ConfigBuildOverrides(
                        ipv6: false,
                        tunEnabled: false,
                        tun: ConfigTUNOverrides(
                            enabled: false,
                            stack: tunStack,
                            autoRoute: runtimeConfiguration.tun.autoRoute,
                            autoDetectInterface: runtimeConfiguration.tun.autoDetectInterface,
                            dnsHijack: nil
                        )
                    )
                )
            )

            _ = RoutingRulesCacheStore.refresh(configurationURL: result.outputURL)

            await MainActor.run {
                NotificationCenter.default.post(name: fluxBarConfigurationDidRefreshNotification, object: nil)
            }

            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "首次启动默认值已初始化：系统代理/IPv6/TUN 默认关闭。"
            )
        } catch {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: "首次启动默认值写入配置失败：\(error.localizedDescription)"
            )
        }
    }
}
