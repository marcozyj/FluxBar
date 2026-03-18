import Foundation

struct PrivilegedTUNHelperStatus: Codable, Sendable {
    let isRunning: Bool
    let pid: Int32?
    let binaryPath: String?
    let configurationPath: String?
    let workingDirectoryPath: String?
    let stdoutPath: String?
    let stderrPath: String?
    let launchedAt: Date?
    let message: String
}

private struct PrivilegedTUNHelperCommand: Codable, Sendable {
    let id: String
    let action: String
    let binaryPath: String?
    let configurationPath: String?
    let workingDirectoryPath: String?
    let arguments: [String]
    let environment: [String: String]
    let stdoutPath: String?
    let stderrPath: String?
}

private struct PrivilegedTUNHelperResponse: Codable, Sendable {
    let id: String
    let success: Bool
    let message: String
    let status: PrivilegedTUNHelperStatus
}

enum PrivilegedTUNHelperPaths {
    static let label = "dev.fluxbar.tun-helper"
    static let installedBinaryURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(label)")
    static let launchDaemonPlistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    static let controlRootURL = URL(fileURLWithPath: "/Library/Application Support/FluxBar/HelperService", isDirectory: true)
    static let commandsURL = controlRootURL.appendingPathComponent("Commands", isDirectory: true)
    static let responsesURL = controlRootURL.appendingPathComponent("Responses", isDirectory: true)
    static let statusURL = controlRootURL.appendingPathComponent("status.json")
    static let logsURL = controlRootURL.appendingPathComponent("Logs", isDirectory: true)

    static func bundledHelperBinaryURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("FluxBarTUNHelper")
    }
}

actor PrivilegedTUNHelperService {
    static let shared = PrivilegedTUNHelperService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    nonisolated static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: PrivilegedTUNHelperPaths.installedBinaryURL.path)
            && FileManager.default.fileExists(atPath: PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)
    }

    nonisolated static func readInstalledStatus() -> PrivilegedTUNHelperStatus? {
        guard let data = try? Data(contentsOf: PrivilegedTUNHelperPaths.statusURL) else {
            return nil
        }

        return try? JSONDecoder().decode(PrivilegedTUNHelperStatus.self, from: data)
    }

    func ensureInstalled() async throws {
        let helperExists = fileManager.fileExists(atPath: PrivilegedTUNHelperPaths.installedBinaryURL.path)
        let plistExists = fileManager.fileExists(atPath: PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)
        let statusExists = fileManager.fileExists(atPath: PrivilegedTUNHelperPaths.statusURL.path)

        if helperExists, plistExists, statusExists {
            return
        }

        throw TUNError.helperServiceUnavailable
    }

    func installHelperServiceManually() async throws {
        try await installHelperService()
    }

    func uninstallHelperService() async throws {
        let script = """
        /bin/launchctl bootout system/\(PrivilegedTUNHelperPaths.label) >/dev/null 2>&1 || true
        /bin/rm -f '\(PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)' '\(PrivilegedTUNHelperPaths.installedBinaryURL.path)'
        /bin/rm -rf '\(PrivilegedTUNHelperPaths.controlRootURL.path)'
        """

        do {
            _ = try runPrivilegedShellCommand(script)
        } catch {
            throw TUNError.privilegedOperationRequired(error.localizedDescription)
        }
    }

    func startKernel(with launchPlan: KernelLaunchPlan) async throws -> PrivilegedTUNHelperStatus {
        try await ensureInstalled()
        let logsRoot = try FluxBarStorageDirectories.logsRoot()
        let stdoutURL = logsRoot.appendingPathComponent("\(launchPlan.kernel.rawValue)-tun.stdout.log")
        let stderrURL = logsRoot.appendingPathComponent("\(launchPlan.kernel.rawValue)-tun.stderr.log")

        let response = try await sendCommand(
            PrivilegedTUNHelperCommand(
                id: UUID().uuidString,
                action: "start",
                binaryPath: launchPlan.binaryURL.path,
                configurationPath: launchPlan.configurationURL?.path,
                workingDirectoryPath: (launchPlan.workingDirectoryURL ?? launchPlan.binaryURL.deletingLastPathComponent()).path,
                arguments: launchPlan.arguments,
                environment: launchPlan.environment,
                stdoutPath: stdoutURL.path,
                stderrPath: stderrURL.path
            )
        )

        guard response.success else {
            throw TUNError.startFailed(response.message)
        }

        return response.status
    }

    func stopKernel() async throws -> PrivilegedTUNHelperStatus {
        let response = try await sendCommand(
            PrivilegedTUNHelperCommand(
                id: UUID().uuidString,
                action: "stop",
                binaryPath: nil,
                configurationPath: nil,
                workingDirectoryPath: nil,
                arguments: [],
                environment: [:],
                stdoutPath: nil,
                stderrPath: nil
            )
        )

        guard response.success else {
            throw TUNError.stopFailed(response.message)
        }

        var latest = response.status
        for _ in 0..<20 {
            if latest.isRunning == false {
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let status = try? await queryStatus() {
                latest = status
            }
        }

        if latest.isRunning {
            throw TUNError.stopFailed(latest.message)
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        return latest
    }

    func queryStatus() async throws -> PrivilegedTUNHelperStatus {
        if PrivilegedTUNHelperService.isInstalled() == false {
            throw TUNError.helperServiceUnavailable
        }

        let response = try await sendCommand(
            PrivilegedTUNHelperCommand(
                id: UUID().uuidString,
                action: "status",
                binaryPath: nil,
                configurationPath: nil,
                workingDirectoryPath: nil,
                arguments: [],
                environment: [:],
                stdoutPath: nil,
                stderrPath: nil
            ),
            timeoutNanoseconds: 3_000_000_000
        )

        return response.status
    }

    private func installHelperService() async throws {
        guard let bundledHelperBinaryURL = PrivilegedTUNHelperPaths.bundledHelperBinaryURL(), fileManager.fileExists(atPath: bundledHelperBinaryURL.path) else {
            throw TUNError.helperServiceInstallFailed("未找到随应用打包的 FluxBarTUNHelper 可执行文件")
        }

        let temporaryPlistURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(PrivilegedTUNHelperPaths.label).plist")
        let plistData = helperLaunchDaemonPlist().data(using: .utf8) ?? Data()
        try plistData.write(to: temporaryPlistURL, options: .atomic)

        let script = """
        /bin/mkdir -p '/Library/PrivilegedHelperTools' \
                      '/Library/LaunchDaemons' \
                      '\(PrivilegedTUNHelperPaths.controlRootURL.path)' \
                      '\(PrivilegedTUNHelperPaths.commandsURL.path)' \
                      '\(PrivilegedTUNHelperPaths.responsesURL.path)' \
                      '\(PrivilegedTUNHelperPaths.logsURL.path)'
        /usr/bin/install -m 755 '\(bundledHelperBinaryURL.path)' '\(PrivilegedTUNHelperPaths.installedBinaryURL.path)'
        /usr/bin/install -m 644 '\(temporaryPlistURL.path)' '\(PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)'
        /usr/sbin/chown root:wheel '\(PrivilegedTUNHelperPaths.installedBinaryURL.path)' '\(PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)'
        /bin/chmod 755 '\(PrivilegedTUNHelperPaths.installedBinaryURL.path)'
        /bin/chmod 644 '\(PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)'
        /usr/sbin/chown -R root:wheel '\(PrivilegedTUNHelperPaths.controlRootURL.path)'
        /bin/chmod 1777 '\(PrivilegedTUNHelperPaths.controlRootURL.path)' '\(PrivilegedTUNHelperPaths.commandsURL.path)' '\(PrivilegedTUNHelperPaths.responsesURL.path)'
        /bin/chmod 755 '\(PrivilegedTUNHelperPaths.logsURL.path)'
        /bin/launchctl bootout system/\(PrivilegedTUNHelperPaths.label) >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system '\(PrivilegedTUNHelperPaths.launchDaemonPlistURL.path)'
        /bin/launchctl enable system/\(PrivilegedTUNHelperPaths.label) >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k system/\(PrivilegedTUNHelperPaths.label)
        """

        do {
            _ = try runPrivilegedShellCommand(script)
        } catch {
            throw TUNError.helperServiceInstallFailed(error.localizedDescription)
        }

        for _ in 0..<20 {
            if fileManager.fileExists(atPath: PrivilegedTUNHelperPaths.statusURL.path) {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TUNError.helperServiceInstallFailed("helper/service 已安装，但未在预期时间内启动")
    }

    private func sendCommand(
        _ command: PrivilegedTUNHelperCommand,
        timeoutNanoseconds: UInt64 = 12_000_000_000
    ) async throws -> PrivilegedTUNHelperResponse {
        let commandURL = PrivilegedTUNHelperPaths.commandsURL.appendingPathComponent("\(command.id).json")
        let temporaryCommandURL = commandURL.appendingPathExtension("tmp")
        let responseURL = PrivilegedTUNHelperPaths.responsesURL.appendingPathComponent("\(command.id).json")

        let data = try encoder.encode(command)
        try data.write(to: temporaryCommandURL, options: .atomic)
        try? fileManager.removeItem(at: commandURL)
        try fileManager.moveItem(at: temporaryCommandURL, to: commandURL)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
            if let responseData = try? Data(contentsOf: responseURL),
               let response = try? decoder.decode(PrivilegedTUNHelperResponse.self, from: responseData) {
                try? fileManager.removeItem(at: responseURL)
                return response
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        throw TUNError.helperServiceUnavailable
    }

    private func helperLaunchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(PrivilegedTUNHelperPaths.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(PrivilegedTUNHelperPaths.installedBinaryURL.path)</string>
                <string>daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(PrivilegedTUNHelperPaths.logsURL.appendingPathComponent("helper.stdout.log").path)</string>
            <key>StandardErrorPath</key>
            <string>\(PrivilegedTUNHelperPaths.logsURL.appendingPathComponent("helper.stderr.log").path)</string>
        </dict>
        </plist>
        """
    }

    private func runPrivilegedShellCommand(_ shellCommand: String) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let script = "do shell script \"\(appleScriptEscaped(shellCommand))\" with administrator privileges"

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TUNError.privilegedOperationRequired(error.localizedDescription)
        }

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TUNError.privilegedOperationRequired(message.isEmpty ? "管理员操作失败" : message)
        }

        return stdout
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
