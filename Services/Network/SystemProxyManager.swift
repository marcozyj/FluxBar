import Foundation

enum SystemProxyMode: String, Sendable, CaseIterable {
    case manual
    case pac
}

struct SystemProxyProfile: Sendable, Equatable {
    var enabled: Bool
    var mode: SystemProxyMode
    var proxyHost: String
    var enableGuard: Bool
    var guardIntervalSeconds: Int
    var useDefaultBypass: Bool
    var customBypass: String
    var autoCloseConnections: Bool
    var pacTemplate: String

    nonisolated static let defaultPACTemplate = """
    function FindProxyForURL(url, host) {
      return "PROXY %proxy_host%:%mixed-port%; SOCKS5 %proxy_host%:%mixed-port%; DIRECT;";
    }
    """

    nonisolated static let `default` = SystemProxyProfile(
        enabled: false,
        mode: .manual,
        proxyHost: "127.0.0.1",
        enableGuard: false,
        guardIntervalSeconds: 30,
        useDefaultBypass: true,
        customBypass: "",
        autoCloseConnections: true,
        pacTemplate: defaultPACTemplate
    )
}

struct SystemProxyRuntimeState: Sendable {
    let enabled: Bool
    let mode: SystemProxyMode?
    let message: String
}

actor SystemProxyManager {
    static let shared = SystemProxyManager()

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct ApplyRequest {
        let profile: SystemProxyProfile
        let configurationURL: URL?
    }

    private let fileManager: FileManager
    private let networksetupPath = "/usr/sbin/networksetup"
    private var pendingRequest: ApplyRequest?
    private var isApplyingRequest = false
    private var guardTask: Task<Void, Never>?
    private var activeProfile: SystemProxyProfile?
    private var activeConfigurationURL: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func applyProxyState(enabled: Bool, configurationURL: URL?) async -> String {
        let profile = profileFromPreferences(enabledOverride: enabled)
        return await applyProxyProfile(profile, configurationURL: configurationURL)
    }

    func applyProxyProfile(_ profile: SystemProxyProfile, configurationURL: URL?) async -> String {
        pendingRequest = ApplyRequest(profile: profile, configurationURL: configurationURL)

        guard isApplyingRequest == false else {
            return "系统代理状态更新已排队"
        }

        isApplyingRequest = true
        defer {
            isApplyingRequest = false
        }

        var lastSummary = "系统代理状态未变更"
        while let request = pendingRequest {
            pendingRequest = nil
            lastSummary = await applySingleRequest(request)
        }

        return lastSummary
    }

    func currentProxyEnabled(configurationURL: URL?) async -> Bool {
        let profile = profileFromPreferences(enabledOverride: nil)
        return currentProxyEnabled(configurationURL: configurationURL, profile: profile)
    }

    func currentRuntimeState(configurationURL: URL?, profile: SystemProxyProfile? = nil) async -> SystemProxyRuntimeState {
        let effectiveProfile = profile ?? profileFromPreferences(enabledOverride: nil)
        let isEnabled = currentProxyEnabled(configurationURL: configurationURL, profile: effectiveProfile)
        let mode: SystemProxyMode? = isEnabled ? effectiveProfile.mode : nil
        let message: String

        if isEnabled {
            switch effectiveProfile.mode {
            case .manual:
                message = "系统代理已开启（普通模式）"
            case .pac:
                message = "系统代理已开启（PAC 模式）"
            }
        } else {
            message = "系统代理已关闭"
        }

        return SystemProxyRuntimeState(enabled: isEnabled, mode: mode, message: message)
    }

    func refreshGuard() async {
        guard let profile = activeProfile, profile.enabled, profile.enableGuard else {
            stopGuardTask()
            return
        }

        startGuardTaskIfNeeded(profile: profile, configurationURL: activeConfigurationURL)
    }

    func disableAllProxies() async -> String {
        stopGuardTask()
        activeProfile = nil
        activeConfigurationURL = nil

        guard fileManager.isExecutableFile(atPath: networksetupPath) else {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: "未找到 networksetup，无法在退出前关闭系统代理。"
            )
            return "未找到系统代理控制工具"
        }

        let services = listNetworkServices()
        guard services.isEmpty == false else {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .warning,
                message: "未发现可用网络服务，跳过系统代理关闭。"
            )
            return "未发现可用网络服务"
        }

        var successfulServices = 0
        var failedServices: [String] = []

        for service in services {
            let commands = [
                ["-setwebproxystate", service, "off"],
                ["-setsecurewebproxystate", service, "off"],
                ["-setsocksfirewallproxystate", service, "off"],
                ["-setautoproxystate", service, "off"]
            ]

            var serviceSucceeded = true
            for arguments in commands {
                let result = runCommand(arguments)
                if result.exitCode != 0 {
                    serviceSucceeded = false
                    await FluxBarLogService.shared.record(
                        source: .app,
                        level: .warning,
                        message: "关闭系统代理失败[\(service)] \(arguments.first ?? ""): \(sanitizedMessage(from: result))"
                    )
                }
            }

            if serviceSucceeded {
                successfulServices += 1
            } else {
                failedServices.append(service)
            }
        }

        let summary: String
        if failedServices.isEmpty {
            summary = "已关闭 \(successfulServices) 个网络服务的系统代理"
        } else {
            summary = "已尝试关闭 \(services.count) 个网络服务的系统代理，失败 \(failedServices.count) 个"
        }

        await FluxBarLogService.shared.record(
            source: .app,
            level: failedServices.isEmpty ? .info : .warning,
            message: summary
        )

        return summary
    }

    private func applySingleRequest(_ request: ApplyRequest) async -> String {
        let profile = request.profile
        if profile.enabled == false {
            if profile.autoCloseConnections {
                await closeAllConnectionsIfNeeded(configurationURL: request.configurationURL)
            }
            return await disableAllProxies()
        }

        let summary: String
        switch profile.mode {
        case .manual:
            summary = await enableManualProxy(profile: profile, configurationURL: request.configurationURL)
        case .pac:
            summary = await enablePACProxy(profile: profile, configurationURL: request.configurationURL)
        }

        activeProfile = profile
        activeConfigurationURL = request.configurationURL

        if profile.enableGuard {
            startGuardTaskIfNeeded(profile: profile, configurationURL: request.configurationURL)
        } else {
            stopGuardTask()
        }

        return summary
    }

    private func enableManualProxy(profile: SystemProxyProfile, configurationURL: URL?) async -> String {
        guard fileManager.isExecutableFile(atPath: networksetupPath) else {
            return "未找到系统代理控制工具"
        }

        guard let port = configuredMixedPort(from: configurationURL) else {
            return "未找到可用混合端口"
        }

        let services = listNetworkServices()
        guard services.isEmpty == false else {
            return "未发现可用网络服务"
        }

        let bypassDomains = mergedBypassDomains(profile: profile)

        var successfulServices = 0
        var failedServices: [String] = []

        for service in services {
            var commands: [[String]] = [
                ["-setautoproxystate", service, "off"],
                ["-setwebproxy", service, profile.proxyHost, "\(port)"],
                ["-setwebproxystate", service, "on"],
                ["-setsecurewebproxy", service, profile.proxyHost, "\(port)"],
                ["-setsecurewebproxystate", service, "on"],
                ["-setsocksfirewallproxy", service, profile.proxyHost, "\(port)"],
                ["-setsocksfirewallproxystate", service, "on"]
            ]
            if bypassDomains.isEmpty == false {
                commands.append(["-setproxybypassdomains", service] + bypassDomains)
            }

            var serviceSucceeded = true
            for arguments in commands {
                let result = runCommand(arguments)
                if result.exitCode != 0 {
                    serviceSucceeded = false
                    await FluxBarLogService.shared.record(
                        source: .app,
                        level: .warning,
                        message: "开启系统代理失败[\(service)] \(arguments.first ?? ""): \(sanitizedMessage(from: result))"
                    )
                }
            }

            if serviceSucceeded {
                successfulServices += 1
            } else {
                failedServices.append(service)
            }
        }

        let summary = failedServices.isEmpty
            ? "已开启 \(successfulServices) 个网络服务的系统代理"
            : "已尝试开启 \(services.count) 个网络服务的系统代理，失败 \(failedServices.count) 个"
        await FluxBarLogService.shared.record(
            source: .app,
            level: failedServices.isEmpty ? .info : .warning,
            message: summary
        )
        return summary
    }

    private func enablePACProxy(profile: SystemProxyProfile, configurationURL: URL?) async -> String {
        guard fileManager.isExecutableFile(atPath: networksetupPath) else {
            return "未找到系统代理控制工具"
        }

        guard let port = configuredMixedPort(from: configurationURL) else {
            return "未找到可用混合端口"
        }

        guard let pacURL = writePACFile(profile: profile, mixedPort: port) else {
            return "写入 PAC 文件失败"
        }

        let services = listNetworkServices()
        guard services.isEmpty == false else {
            return "未发现可用网络服务"
        }

        var successfulServices = 0
        var failedServices: [String] = []

        for service in services {
            let commands = [
                ["-setwebproxystate", service, "off"],
                ["-setsecurewebproxystate", service, "off"],
                ["-setsocksfirewallproxystate", service, "off"],
                ["-setautoproxyurl", service, pacURL.absoluteString],
                ["-setautoproxystate", service, "on"]
            ]

            var serviceSucceeded = true
            for arguments in commands {
                let result = runCommand(arguments)
                if result.exitCode != 0 {
                    serviceSucceeded = false
                    await FluxBarLogService.shared.record(
                        source: .app,
                        level: .warning,
                        message: "开启 PAC 代理失败[\(service)] \(arguments.first ?? ""): \(sanitizedMessage(from: result))"
                    )
                }
            }

            if serviceSucceeded {
                successfulServices += 1
            } else {
                failedServices.append(service)
            }
        }

        let summary = failedServices.isEmpty
            ? "已开启 \(successfulServices) 个网络服务的 PAC 代理"
            : "已尝试开启 \(services.count) 个网络服务的 PAC 代理，失败 \(failedServices.count) 个"
        await FluxBarLogService.shared.record(
            source: .app,
            level: failedServices.isEmpty ? .info : .warning,
            message: summary
        )
        return summary
    }

    private func startGuardTaskIfNeeded(profile: SystemProxyProfile, configurationURL: URL?) {
        stopGuardTask()

        guard profile.enabled, profile.enableGuard else {
            return
        }

        let interval = max(5, profile.guardIntervalSeconds)
        guardTask = Task {
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled {
                    break
                }

                let currentEnabled = currentProxyEnabled(configurationURL: configurationURL, profile: profile)
                if currentEnabled == false {
                    _ = await applyProxyProfile(profile, configurationURL: configurationURL)
                }
            }
        }
    }

    private func stopGuardTask() {
        guardTask?.cancel()
        guardTask = nil
    }

    private func closeAllConnectionsIfNeeded(configurationURL: URL?) async {
        guard
            let context = FluxBarConfigurationSupport.controllerContext(from: configurationURL)
        else {
            return
        }

        let client = MihomoControllerClient(configuration: context.configuration)
        _ = try? await client.closeAllConnections()
    }

    private func profileFromPreferences(enabledOverride: Bool?) -> SystemProxyProfile {
        let enabled = enabledOverride ?? FluxBarPreferences.bool(for: "settings.systemProxyEnabled", fallback: false)
        let pacMode = FluxBarPreferences.bool(for: "settings.proxyAutoConfig", fallback: false)
        let proxyHost = FluxBarPreferences.string(for: "settings.proxyHost", fallback: "127.0.0.1")
        let enableGuard = FluxBarPreferences.bool(for: "settings.enableProxyGuard", fallback: false)
        let guardInterval = Int(FluxBarPreferences.string(for: "settings.proxyGuardDuration", fallback: "30")) ?? 30
        let useDefaultBypass = FluxBarPreferences.bool(for: "settings.useDefaultBypass", fallback: true)
        let customBypass = FluxBarPreferences.string(for: "settings.systemProxyBypass", fallback: "")
        let autoCloseConnections = FluxBarPreferences.bool(for: "settings.autoCloseConnections", fallback: true)
        let pacTemplate = FluxBarPreferences.string(for: "settings.pacFileContent", fallback: SystemProxyProfile.defaultPACTemplate)

        return SystemProxyProfile(
            enabled: enabled,
            mode: pacMode ? .pac : .manual,
            proxyHost: proxyHost.isEmpty ? "127.0.0.1" : proxyHost,
            enableGuard: enableGuard,
            guardIntervalSeconds: max(5, guardInterval),
            useDefaultBypass: useDefaultBypass,
            customBypass: customBypass,
            autoCloseConnections: autoCloseConnections,
            pacTemplate: pacTemplate.isEmpty ? SystemProxyProfile.defaultPACTemplate : pacTemplate
        )
    }

    private func mergedBypassDomains(profile: SystemProxyProfile) -> [String] {
        var domains: [String] = []
        if profile.useDefaultBypass {
            domains.append(contentsOf: defaultBypassDomains())
        }
        domains.append(contentsOf: splitBypass(profile.customBypass))

        var seen = Set<String>()
        return domains.filter { domain in
            let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else {
                return false
            }
            if seen.contains(normalized) {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }

    private func splitBypass(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { ",;\n\r".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private func defaultBypassDomains() -> [String] {
        [
            "127.0.0.1",
            "192.168.0.0/16",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "localhost",
            "*.local",
            "*.crashlytics.com",
            "<local>"
        ]
    }

    private func writePACFile(profile: SystemProxyProfile, mixedPort: Int) -> URL? {
        guard let stateRoot = try? FluxBarStorageDirectories.stateRoot(fileManager: fileManager) else {
            return nil
        }

        let pacURL = stateRoot.appendingPathComponent("system-proxy.pac", isDirectory: false)
        let content = profile.pacTemplate
            .replacingOccurrences(of: "%proxy_host%", with: profile.proxyHost)
            .replacingOccurrences(of: "%mixed-port%", with: "\(mixedPort)")
        do {
            try content.write(to: pacURL, atomically: true, encoding: .utf8)
            return pacURL
        } catch {
            return nil
        }
    }

    private func currentProxyEnabled(configurationURL: URL?, profile: SystemProxyProfile) -> Bool {
        guard
            let configurationURL,
            let port = configuredMixedPort(from: configurationURL)
        else {
            return false
        }

        let services = listNetworkServices()
        guard services.isEmpty == false else {
            return false
        }

        switch profile.mode {
        case .manual:
            for service in services {
                let webProxy = runCommand(["-getwebproxy", service])
                let secureProxy = runCommand(["-getsecurewebproxy", service])
                let socksProxy = runCommand(["-getsocksfirewallproxy", service])

                if proxyResult(webProxy, matchesHost: profile.proxyHost, port: port)
                    || proxyResult(secureProxy, matchesHost: profile.proxyHost, port: port)
                    || proxyResult(socksProxy, matchesHost: profile.proxyHost, port: port) {
                    return true
                }
            }
            return false
        case .pac:
            let expectedPACURL = writePACFile(profile: profile, mixedPort: port)
            for service in services {
                let pacResult = runCommand(["-getautoproxyurl", service])
                if autoproxyResult(
                    pacResult,
                    expectedURL: expectedPACURL?.absoluteString ?? "",
                    allowAnyURLWhenExpectedMissing: expectedPACURL == nil
                ) {
                    return true
                }
            }
            return false
        }
    }

    private func listNetworkServices() -> [String] {
        let result = runCommand(["-listallnetworkservices"])
        guard result.exitCode == 0 else {
            return []
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.isEmpty == false else {
                    return false
                }

                if line.hasPrefix("*") {
                    return false
                }

                if line.contains("denotes that a network service is disabled") {
                    return false
                }

                return true
            }
    }

    private func runCommand(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: networksetupPath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func sanitizedMessage(from result: CommandResult) -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exit=\(result.exitCode)" : trimmed
    }

    private func configuredMixedPort(from configurationURL: URL?) -> Int? {
        guard
            let configurationURL,
            let text = try? String(contentsOf: configurationURL, encoding: .utf8)
        else {
            return nil
        }

        if let mixedPort = scalarValue(for: "mixed-port", in: text).flatMap(Int.init) {
            return mixedPort
        }

        return scalarValue(for: "port", in: text).flatMap(Int.init)
    }

    private func scalarValue(for key: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.hasPrefix("#") == false && line.hasPrefix("\(key):")
            }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }

    private func proxyResult(_ result: CommandResult, matchesHost host: String, port: Int) -> Bool {
        guard result.exitCode == 0 else {
            return false
        }

        let lines = result.stdout.components(separatedBy: .newlines)
        var enabled = false
        var server = ""
        var serverPort = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.localizedCaseInsensitiveContains("yes")
            } else if trimmed.hasPrefix("Server:") {
                server = trimmed.replacingOccurrences(of: "Server:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("Port:") {
                serverPort = trimmed.replacingOccurrences(of: "Port:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return enabled && server == host && serverPort == "\(port)"
    }

    private func autoproxyResult(_ result: CommandResult, expectedURL: String, allowAnyURLWhenExpectedMissing: Bool) -> Bool {
        guard result.exitCode == 0 else {
            return false
        }

        let lines = result.stdout.components(separatedBy: .newlines)
        var enabled = false
        var url = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.localizedCaseInsensitiveContains("yes")
            } else if trimmed.hasPrefix("URL:") {
                url = trimmed.replacingOccurrences(of: "URL:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if allowAnyURLWhenExpectedMissing {
            return enabled && url.isEmpty == false
        }

        return enabled && url == expectedURL
    }
}
