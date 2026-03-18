import Foundation
import Darwin

private struct HelperCommand: Codable {
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

private struct HelperStatus: Codable {
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

private struct HelperResponse: Codable {
    let id: String
    let success: Bool
    let message: String
    let status: HelperStatus
}

private enum HelperPaths {
    static let label = "dev.fluxbar.tun-helper"
    static let controlRoot = URL(fileURLWithPath: "/Library/Application Support/FluxBar/HelperService", isDirectory: true)
    static let commands = controlRoot.appendingPathComponent("Commands", isDirectory: true)
    static let responses = controlRoot.appendingPathComponent("Responses", isDirectory: true)
    static let logs = controlRoot.appendingPathComponent("Logs", isDirectory: true)
    static let status = controlRoot.appendingPathComponent("status.json")
}

private final class HelperDaemon: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var activeProcess: Process?
    private var cachedStatus: HelperStatus

    init() {
        cachedStatus = Self.loadStatus() ?? HelperStatus(
            isRunning: false,
            pid: nil,
            binaryPath: nil,
            configurationPath: nil,
            workingDirectoryPath: nil,
            stdoutPath: nil,
            stderrPath: nil,
            launchedAt: nil,
            message: "helper service 已就绪"
        )
    }

    func run() {
        ensureDirectories()
        refreshStatus()
        writeStatus(cachedStatus)

        while true {
            refreshStatus()
            processPendingCommands()
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func processPendingCommands() {
        guard let items = try? fileManager.contentsOfDirectory(at: HelperPaths.commands, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]),
              items.isEmpty == false else {
            return
        }

        let sorted = items.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return leftDate < rightDate
        }

        guard let commandURL = sorted.first,
              let data = try? Data(contentsOf: commandURL),
              let command = try? decoder.decode(HelperCommand.self, from: data) else {
            return
        }

        let response = handle(command)
        writeResponse(response)
        try? fileManager.removeItem(at: commandURL)
    }

    private func handle(_ command: HelperCommand) -> HelperResponse {
        switch command.action {
        case "start":
            return handleStart(command)
        case "stop":
            return handleStop(command)
        case "status":
            refreshStatus()
            return HelperResponse(id: command.id, success: true, message: cachedStatus.message, status: cachedStatus)
        default:
            return HelperResponse(id: command.id, success: false, message: "未知操作：\(command.action)", status: cachedStatus)
        }
    }

    private func handleStart(_ command: HelperCommand) -> HelperResponse {
        refreshStatus()
        if let pid = cachedStatus.pid, processExists(pid) {
            return HelperResponse(id: command.id, success: true, message: "内核已运行", status: cachedStatus)
        }

        guard let binaryPath = command.binaryPath, binaryPath.isEmpty == false else {
            return HelperResponse(id: command.id, success: false, message: "缺少内核二进制路径", status: cachedStatus)
        }

        let stdoutPath = command.stdoutPath ?? HelperPaths.logs.appendingPathComponent("mihomo.stdout.log").path
        let stderrPath = command.stderrPath ?? HelperPaths.logs.appendingPathComponent("mihomo.stderr.log").path
        let stdoutURL = URL(fileURLWithPath: stdoutPath)
        let stderrURL = URL(fileURLWithPath: stderrPath)
        ensureParentDirectory(for: stdoutURL)
        ensureParentDirectory(for: stderrURL)
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = command.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
            if let workingDirectoryPath = command.workingDirectoryPath, workingDirectoryPath.isEmpty == false {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
            }

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            try stdoutHandle.seekToEnd()
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            try stderrHandle.seekToEnd()
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            process.terminationHandler = { [weak self] process in
                self?.handleTermination(of: process)
            }

            try process.run()
            activeProcess = process
            cachedStatus = HelperStatus(
                isRunning: true,
                pid: process.processIdentifier,
                binaryPath: binaryPath,
                configurationPath: command.configurationPath,
                workingDirectoryPath: command.workingDirectoryPath,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath,
                launchedAt: Date(),
                message: "内核已通过 helper service 启动"
            )
            writeStatus(cachedStatus)
            return HelperResponse(id: command.id, success: true, message: cachedStatus.message, status: cachedStatus)
        } catch {
            cachedStatus = HelperStatus(
                isRunning: false,
                pid: nil,
                binaryPath: binaryPath,
                configurationPath: command.configurationPath,
                workingDirectoryPath: command.workingDirectoryPath,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath,
                launchedAt: nil,
                message: error.localizedDescription
            )
            writeStatus(cachedStatus)
            return HelperResponse(id: command.id, success: false, message: error.localizedDescription, status: cachedStatus)
        }
    }

    private func handleStop(_ command: HelperCommand) -> HelperResponse {
        refreshStatus()
        guard let pid = cachedStatus.pid, processExists(pid) else {
            cachedStatus = HelperStatus(
                isRunning: false,
                pid: nil,
                binaryPath: cachedStatus.binaryPath,
                configurationPath: cachedStatus.configurationPath,
                workingDirectoryPath: cachedStatus.workingDirectoryPath,
                stdoutPath: cachedStatus.stdoutPath,
                stderrPath: cachedStatus.stderrPath,
                launchedAt: cachedStatus.launchedAt,
                message: "内核当前未运行"
            )
            writeStatus(cachedStatus)
            return HelperResponse(id: command.id, success: true, message: cachedStatus.message, status: cachedStatus)
        }

        if let activeProcess, activeProcess.isRunning {
            activeProcess.terminate()
            waitForExit(of: pid, checks: 30)
            if processExists(pid) {
                _ = Darwin.kill(pid, SIGKILL)
                waitForExit(of: pid, checks: 20)
            }
        } else {
            _ = Darwin.kill(pid, SIGTERM)
            waitForExit(of: pid, checks: 30)
            if processExists(pid) {
                _ = Darwin.kill(pid, SIGKILL)
                waitForExit(of: pid, checks: 20)
            }
        }

        if processExists(pid) {
            cachedStatus = HelperStatus(
                isRunning: true,
                pid: pid,
                binaryPath: cachedStatus.binaryPath,
                configurationPath: cachedStatus.configurationPath,
                workingDirectoryPath: cachedStatus.workingDirectoryPath,
                stdoutPath: cachedStatus.stdoutPath,
                stderrPath: cachedStatus.stderrPath,
                launchedAt: cachedStatus.launchedAt,
                message: "内核停止超时，进程仍存活"
            )
            writeStatus(cachedStatus)
            return HelperResponse(id: command.id, success: false, message: cachedStatus.message, status: cachedStatus)
        }

        activeProcess = nil
        if waitForConfiguredPortsToRelease(configurationPath: cachedStatus.configurationPath, checks: 80) == false {
            cachedStatus = HelperStatus(
                isRunning: false,
                pid: nil,
                binaryPath: cachedStatus.binaryPath,
                configurationPath: cachedStatus.configurationPath,
                workingDirectoryPath: cachedStatus.workingDirectoryPath,
                stdoutPath: cachedStatus.stdoutPath,
                stderrPath: cachedStatus.stderrPath,
                launchedAt: cachedStatus.launchedAt,
                message: "端口占用：9090 或 7890 未释放"
            )
            writeStatus(cachedStatus)
            return HelperResponse(id: command.id, success: false, message: cachedStatus.message, status: cachedStatus)
        }

        cachedStatus = HelperStatus(
            isRunning: false,
            pid: nil,
            binaryPath: cachedStatus.binaryPath,
            configurationPath: cachedStatus.configurationPath,
            workingDirectoryPath: cachedStatus.workingDirectoryPath,
            stdoutPath: cachedStatus.stdoutPath,
            stderrPath: cachedStatus.stderrPath,
            launchedAt: cachedStatus.launchedAt,
            message: "内核已停止"
        )
        writeStatus(cachedStatus)
        return HelperResponse(id: command.id, success: true, message: cachedStatus.message, status: cachedStatus)
    }

    private func handleTermination(of process: Process) {
        guard cachedStatus.pid == process.processIdentifier else {
            return
        }

        activeProcess = nil
        cachedStatus = HelperStatus(
            isRunning: false,
            pid: nil,
            binaryPath: cachedStatus.binaryPath,
            configurationPath: cachedStatus.configurationPath,
            workingDirectoryPath: cachedStatus.workingDirectoryPath,
            stdoutPath: cachedStatus.stdoutPath,
            stderrPath: cachedStatus.stderrPath,
            launchedAt: cachedStatus.launchedAt,
            message: process.terminationStatus == 0 ? "内核已退出" : "内核异常退出 (\(process.terminationStatus))"
        )
        writeStatus(cachedStatus)
    }

    private func refreshStatus() {
        if let pid = cachedStatus.pid, processExists(pid) == false {
            activeProcess = nil
            cachedStatus = HelperStatus(
                isRunning: false,
                pid: nil,
                binaryPath: cachedStatus.binaryPath,
                configurationPath: cachedStatus.configurationPath,
                workingDirectoryPath: cachedStatus.workingDirectoryPath,
                stdoutPath: cachedStatus.stdoutPath,
                stderrPath: cachedStatus.stderrPath,
                launchedAt: cachedStatus.launchedAt,
                message: "内核当前未运行"
            )
            writeStatus(cachedStatus)
        }
    }

    private func writeResponse(_ response: HelperResponse) {
        let responseURL = HelperPaths.responses.appendingPathComponent("\(response.id).json")
        guard let data = try? encoder.encode(response) else {
            return
        }
        writeAtomically(data, to: responseURL)
    }

    private func writeStatus(_ status: HelperStatus) {
        guard let data = try? encoder.encode(status) else {
            return
        }
        writeAtomically(data, to: HelperPaths.status)
    }

    private func writeAtomically(_ data: Data, to url: URL) {
        let temporaryURL = url.appendingPathExtension("tmp")
        try? data.write(to: temporaryURL, options: .atomic)
        try? fileManager.removeItem(at: url)
        try? fileManager.moveItem(at: temporaryURL, to: url)
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: HelperPaths.controlRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: HelperPaths.commands, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: HelperPaths.responses, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: HelperPaths.logs, withIntermediateDirectories: true)
    }

    private func ensureParentDirectory(for url: URL) {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func waitForExit(of pid: Int32, checks: Int) {
        for _ in 0..<checks where processExists(pid) {
            usleep(100_000)
        }
    }

    private func waitForConfiguredPortsToRelease(configurationPath: String?, checks: Int) -> Bool {
        let ports = configuredPorts(from: configurationPath)
        guard ports.isEmpty == false else {
            return true
        }

        for _ in 0..<checks {
            if ports.allSatisfy({ isListening(on: $0) == false }) {
                return true
            }
            usleep(200_000)
        }

        return ports.allSatisfy { isListening(on: $0) == false }
    }

    private func configuredPorts(from configurationPath: String?) -> [Int] {
        guard
            let configurationPath,
            let content = try? String(contentsOfFile: configurationPath, encoding: .utf8)
        else {
            return [7890, 9090]
        }

        var ports = Set<Int>()
        ports.insert(scalarIntValue(for: "mixed-port", in: content) ?? 7890)

        if let controller = scalarStringValue(for: "external-controller", in: content),
           let port = controller.split(separator: ":").last.flatMap({ Int($0) }) {
            ports.insert(port)
        } else {
            ports.insert(9090)
        }

        return Array(ports)
    }

    private func scalarStringValue(for key: String, in content: String) -> String? {
        content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("#") == false && $0.hasPrefix("\(key):") }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }

    private func scalarIntValue(for key: String, in content: String) -> Int? {
        scalarStringValue(for: key, in: content).flatMap(Int.init)
    }

    private func isListening(on port: Int) -> Bool {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 1 else {
            return false
        }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func loadStatus() -> HelperStatus? {
        guard let data = try? Data(contentsOf: HelperPaths.status) else {
            return nil
        }
        return try? JSONDecoder().decode(HelperStatus.self, from: data)
    }
}

@main
struct FluxBarTUNHelper {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "daemon" {
            let daemon = HelperDaemon()
            daemon.run()
            return
        }

        fputs("FluxBarTUNHelper is intended to run as a launch daemon.\n", stderr)
        exit(64)
    }
}
