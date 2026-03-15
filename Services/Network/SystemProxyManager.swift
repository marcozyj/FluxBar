import Foundation

actor SystemProxyManager {
    static let shared = SystemProxyManager()

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private let fileManager: FileManager
    private let networksetupPath = "/usr/sbin/networksetup"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func applyProxyState(enabled: Bool, configurationURL: URL?) async -> String {
        if enabled {
            return await enableConfiguredProxy(using: configurationURL)
        }

        return await disableAllProxies()
    }

    func currentProxyEnabled(configurationURL: URL?) async -> Bool {
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

        for service in services {
            let webProxy = runCommand(["-getwebproxy", service])
            let secureProxy = runCommand(["-getsecurewebproxy", service])
            let socksProxy = runCommand(["-getsocksfirewallproxy", service])

            if proxyResult(webProxy, matchesHost: "127.0.0.1", port: port)
                || proxyResult(secureProxy, matchesHost: "127.0.0.1", port: port)
                || proxyResult(socksProxy, matchesHost: "127.0.0.1", port: port) {
                return true
            }
        }

        return false
    }

    func disableAllProxies() async -> String {
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

    private func enableConfiguredProxy(using configurationURL: URL?) async -> String {
        guard fileManager.isExecutableFile(atPath: networksetupPath) else {
            return "未找到系统代理控制工具"
        }

        guard
            let configurationURL,
            let port = configuredMixedPort(from: configurationURL)
        else {
            return "未找到可用混合端口"
        }

        let services = listNetworkServices()
        guard services.isEmpty == false else {
            return "未发现可用网络服务"
        }

        var successfulServices = 0
        var failedServices: [String] = []

        for service in services {
            let commands = [
                ["-setwebproxy", service, "127.0.0.1", "\(port)"],
                ["-setwebproxystate", service, "on"],
                ["-setsecurewebproxy", service, "127.0.0.1", "\(port)"],
                ["-setsecurewebproxystate", service, "on"],
                ["-setsocksfirewallproxy", service, "127.0.0.1", "\(port)"],
                ["-setsocksfirewallproxystate", service, "on"]
            ]

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

        let summary: String
        if failedServices.isEmpty {
            summary = "已开启 \(successfulServices) 个网络服务的系统代理"
        } else {
            summary = "已尝试开启 \(services.count) 个网络服务的系统代理，失败 \(failedServices.count) 个"
        }

        await FluxBarLogService.shared.record(
            source: .app,
            level: failedServices.isEmpty ? .info : .warning,
            message: summary
        )

        return summary
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

    private func configuredMixedPort(from configurationURL: URL) -> Int? {
        guard let text = try? String(contentsOf: configurationURL, encoding: .utf8) else {
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
}
