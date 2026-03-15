import Foundation
import Darwin

private final class RunningKernelProcess {
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let launchPlan: KernelLaunchPlan

    nonisolated init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe, launchPlan: KernelLaunchPlan) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.launchPlan = launchPlan
    }
}

private struct PrivilegedKernelProcess {
    let pid: Int32
    let launchPlan: KernelLaunchPlan
    let stdoutURL: URL
    let stderrURL: URL
    let launchedAt: Date
}

actor KernelManager {
    static let shared = KernelManager()

    private let binaryLocator: any KernelBinaryLocating
    private let runtimes: [KernelType: any KernelRuntime]
    private let fileManager: FileManager

    private var selectedKernel: KernelType
    private var activeProcess: RunningKernelProcess?
    private var privilegedProcess: PrivilegedKernelProcess?
    private var lastStartRequests: [KernelType: KernelStartRequest]
    private var statusSnapshots: [KernelType: KernelStatusSnapshot]
    private var recentOutput: [KernelType: [String]]

    init(
        selectedKernel: KernelType = .mihomo,
        binaryLocator: any KernelBinaryLocating = DefaultKernelBinaryLocator(),
        fileManager: FileManager = .default,
        runtimes: [any KernelRuntime] = [
            MihomoKernelRuntime(),
            SmartKernelRuntime()
        ]
    ) {
        self.selectedKernel = selectedKernel
        self.binaryLocator = binaryLocator
        self.fileManager = fileManager
        self.lastStartRequests = [:]
        self.recentOutput = [:]

        var runtimeMap: [KernelType: any KernelRuntime] = [:]
        for runtime in runtimes {
            runtimeMap[runtime.kernel] = runtime
        }
        self.runtimes = runtimeMap

        var snapshots: [KernelType: KernelStatusSnapshot] = [:]
        for kernel in KernelType.allCases {
            snapshots[kernel] = .idle(for: kernel, message: "内核尚未启动")
        }
        self.statusSnapshots = snapshots
    }

    func selectKernel(_ kernel: KernelType) -> KernelStatusSnapshot {
        selectedKernel = kernel
        return runningStatus(for: kernel)
    }

    func start(_ request: KernelStartRequest) async throws -> KernelStatusSnapshot {
        if let activeProcess, activeProcess.process.isRunning {
            if activeProcess.launchPlan.kernel == request.kernel {
                return runningStatus(for: request.kernel)
            }

            _ = await stop()
        } else if let privilegedProcess, processExists(privilegedProcess.pid) {
            if privilegedProcess.launchPlan.kernel == request.kernel {
                return runningStatus(for: request.kernel)
            }

            _ = await stop()
        }

        guard let runtime = runtimes[request.kernel] else {
            throw KernelError.runtimeUnavailable(request.kernel)
        }

        let binaryURL = try binaryLocator.binaryURL(for: request.kernel, preferredURL: request.binaryURL)
        let launchPlan = try runtime.makeLaunchPlan(from: request, resolvedBinaryURL: binaryURL)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = launchPlan.binaryURL
        process.arguments = launchPlan.arguments
        process.environment = mergedEnvironment(with: launchPlan.environment)
        process.currentDirectoryURL = launchPlan.workingDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let bootingSnapshot = KernelStatusSnapshot(
            kernel: request.kernel,
            phase: .starting,
            processIdentifier: nil,
            binaryURL: binaryURL,
            configurationURL: launchPlan.configurationURL,
            launchedAt: nil,
            lastExitCode: nil,
            message: "正在启动 \(request.kernel.displayName)"
        )
        statusSnapshots[request.kernel] = bootingSnapshot
        recentOutput[request.kernel] = []
        await FluxBarLogService.shared.record(
            source: request.kernel == .mihomo ? .mihomo : .smart,
            level: .info,
            message: "准备启动 \(request.kernel.displayName) 内核"
        )
        await logTUNConfigurationIfNeeded(for: request.kernel, configurationURL: launchPlan.configurationURL)

        do {
            if shouldUsePrivilegedLaunch(for: launchPlan) {
                let privilegedProcess = try await launchPrivilegedKernel(with: launchPlan)
                self.privilegedProcess = privilegedProcess
                lastStartRequests[request.kernel] = request
                selectedKernel = request.kernel

                let runningSnapshot = KernelStatusSnapshot(
                    kernel: request.kernel,
                    phase: .running,
                    processIdentifier: privilegedProcess.pid,
                    binaryURL: binaryURL,
                    configurationURL: launchPlan.configurationURL,
                    launchedAt: privilegedProcess.launchedAt,
                    lastExitCode: nil,
                    message: "已启动 \(request.kernel.displayName)（TUN/管理员模式）"
                )
                statusSnapshots[request.kernel] = runningSnapshot
                await FluxBarLogService.shared.record(
                    source: request.kernel == .mihomo ? .mihomo : .smart,
                    level: .info,
                    message: "\(request.kernel.displayName) 已以管理员模式启动，PID \(privilegedProcess.pid)"
                )
                return runningSnapshot
            }

            try process.run()
        } catch {
            let failedSnapshot = KernelStatusSnapshot(
                kernel: request.kernel,
                phase: .failed,
                processIdentifier: nil,
                binaryURL: binaryURL,
                configurationURL: launchPlan.configurationURL,
                launchedAt: nil,
                lastExitCode: nil,
                message: error.localizedDescription
            )
            statusSnapshots[request.kernel] = failedSnapshot
            await FluxBarLogService.shared.record(
                source: request.kernel == .mihomo ? .mihomo : .smart,
                level: .error,
                message: "\(request.kernel.displayName) 启动失败：\(error.localizedDescription)"
            )
            throw launchError(for: request.kernel, underlying: error.localizedDescription)
        }

        let running = RunningKernelProcess(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            launchPlan: launchPlan
        )
        activeProcess = running
        lastStartRequests[request.kernel] = request
        selectedKernel = request.kernel

        beginCapturingOutput(for: request.kernel, from: stdoutPipe)
        beginCapturingOutput(for: request.kernel, from: stderrPipe)

        process.terminationHandler = { [weak self] process in
            Task {
                await self?.handleTermination(
                    for: request.kernel,
                    processIdentifier: process.processIdentifier,
                    exitCode: process.terminationStatus
                )
            }
        }

        guard await waitForStartupStability(of: process) else {
            let currentSnapshot = statusSnapshots[request.kernel]
            let failureMessage = startupFailureMessage(
                for: request.kernel,
                exitCode: process.terminationStatus,
                fallback: currentSnapshot?.message
            )

            if activeProcess?.process.processIdentifier == process.processIdentifier {
                activeProcess?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                activeProcess?.stderrPipe.fileHandleForReading.readabilityHandler = nil
                activeProcess = nil
            }

            let failedSnapshot = KernelStatusSnapshot(
                kernel: request.kernel,
                phase: .failed,
                processIdentifier: nil,
                binaryURL: binaryURL,
                configurationURL: launchPlan.configurationURL,
                launchedAt: nil,
                lastExitCode: process.terminationStatus,
                message: failureMessage
            )
            statusSnapshots[request.kernel] = failedSnapshot
            throw KernelError.launchFailed(request.kernel, underlying: failureMessage)
        }

        let runningSnapshot = KernelStatusSnapshot(
            kernel: request.kernel,
            phase: .running,
            processIdentifier: process.processIdentifier,
            binaryURL: binaryURL,
            configurationURL: launchPlan.configurationURL,
            launchedAt: Date(),
            lastExitCode: nil,
            message: "已启动 \(request.kernel.displayName)"
        )
        statusSnapshots[request.kernel] = runningSnapshot
        await FluxBarLogService.shared.record(
            source: request.kernel == .mihomo ? .mihomo : .smart,
            level: .info,
            message: "\(request.kernel.displayName) 已启动，PID \(process.processIdentifier)"
        )

        return runningSnapshot
    }

    func stop() async -> KernelStatusSnapshot {
        let kernel = activeProcess?.launchPlan.kernel ?? privilegedProcess?.launchPlan.kernel ?? selectedKernel

        guard activeProcess != nil || privilegedProcess != nil else {
            let snapshot = KernelStatusSnapshot.idle(for: kernel, message: "内核当前未运行")
            statusSnapshots[kernel] = snapshot
            return snapshot
        }

        let stoppingProcessIdentifier = activeProcess?.process.processIdentifier ?? privilegedProcess?.pid
        let stoppingBinaryURL = activeProcess?.launchPlan.binaryURL ?? privilegedProcess?.launchPlan.binaryURL
        let stoppingConfigurationURL = activeProcess?.launchPlan.configurationURL ?? privilegedProcess?.launchPlan.configurationURL

        statusSnapshots[kernel] = KernelStatusSnapshot(
            kernel: kernel,
            phase: .stopping,
            processIdentifier: stoppingProcessIdentifier,
            binaryURL: stoppingBinaryURL,
            configurationURL: stoppingConfigurationURL,
            launchedAt: nil,
            lastExitCode: nil,
            message: "正在停止 \(kernel.displayName)"
        )
        await FluxBarLogService.shared.record(
            source: kernel == .mihomo ? .mihomo : .smart,
            level: .info,
            message: "正在停止 \(kernel.displayName) 内核"
        )

        if let privilegedProcess {
            do {
                try await stopPrivilegedKernel(privilegedProcess)
            } catch {
                let failedSnapshot = KernelStatusSnapshot(
                    kernel: kernel,
                    phase: .failed,
                    processIdentifier: privilegedProcess.pid,
                    binaryURL: privilegedProcess.launchPlan.binaryURL,
                    configurationURL: privilegedProcess.launchPlan.configurationURL,
                    launchedAt: privilegedProcess.launchedAt,
                    lastExitCode: nil,
                    message: error.localizedDescription
                )
                statusSnapshots[kernel] = failedSnapshot
                await FluxBarLogService.shared.record(
                    source: kernel == .mihomo ? .mihomo : .smart,
                    level: .error,
                    message: "\(kernel.displayName) 停止失败：\(error.localizedDescription)"
                )
                return failedSnapshot
            }

            self.privilegedProcess = nil

            let stoppedSnapshot = KernelStatusSnapshot(
                kernel: kernel,
                phase: .stopped,
                processIdentifier: nil,
                binaryURL: privilegedProcess.launchPlan.binaryURL,
                configurationURL: privilegedProcess.launchPlan.configurationURL,
                launchedAt: privilegedProcess.launchedAt,
                lastExitCode: 0,
                message: "已停止 \(kernel.displayName)"
            )
            statusSnapshots[kernel] = stoppedSnapshot
            await FluxBarLogService.shared.record(
                source: kernel == .mihomo ? .mihomo : .smart,
                level: .info,
                message: "\(kernel.displayName) 已停止（管理员模式）"
            )
            return stoppedSnapshot
        }

        guard let activeProcess else {
            let snapshot = KernelStatusSnapshot.idle(for: kernel, message: "内核当前未运行")
            statusSnapshots[kernel] = snapshot
            return snapshot
        }

        if activeProcess.process.isRunning {
            activeProcess.process.terminate()

            if await waitForProcessExit(activeProcess.process, checks: 20, intervalNanoseconds: 100_000_000) == false {
                await FluxBarLogService.shared.record(
                    source: kernel == .mihomo ? .mihomo : .smart,
                    level: .warning,
                    message: "\(kernel.displayName) 在正常停止超时后执行强制终止"
                )
                forceTerminate(activeProcess.process)
                _ = await waitForProcessExit(activeProcess.process, checks: 10, intervalNanoseconds: 100_000_000)
            }
        }

        activeProcess.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        activeProcess.stderrPipe.fileHandleForReading.readabilityHandler = nil
        self.activeProcess = nil

        let stoppedSnapshot = KernelStatusSnapshot(
            kernel: kernel,
            phase: .stopped,
            processIdentifier: nil,
            binaryURL: activeProcess.launchPlan.binaryURL,
            configurationURL: activeProcess.launchPlan.configurationURL,
            launchedAt: nil,
            lastExitCode: activeProcess.process.terminationStatus,
            message: "已停止 \(kernel.displayName)"
        )
        statusSnapshots[kernel] = stoppedSnapshot
        await FluxBarLogService.shared.record(
            source: kernel == .mihomo ? .mihomo : .smart,
            level: .info,
            message: "\(kernel.displayName) 已停止，退出码 \(activeProcess.process.terminationStatus)"
        )
        return stoppedSnapshot
    }

    func restart() async throws -> KernelStatusSnapshot {
        guard let request = lastStartRequests[selectedKernel] ?? lastStartRequests[activeProcess?.launchPlan.kernel ?? selectedKernel] else {
            throw KernelError.noPreviousLaunchConfiguration(selectedKernel)
        }

        _ = await stop()
        return try await start(request)
    }

    func runningStatus(for kernel: KernelType? = nil) -> KernelStatusSnapshot {
        let targetKernel = kernel ?? activeProcess?.launchPlan.kernel ?? privilegedProcess?.launchPlan.kernel ?? selectedKernel

        if let activeProcess, activeProcess.launchPlan.kernel == targetKernel, activeProcess.process.isRunning {
            let current = statusSnapshots[targetKernel]
            return KernelStatusSnapshot(
                kernel: targetKernel,
                phase: .running,
                processIdentifier: activeProcess.process.processIdentifier,
                binaryURL: activeProcess.launchPlan.binaryURL,
                configurationURL: activeProcess.launchPlan.configurationURL,
                launchedAt: current?.launchedAt ?? Date(),
                lastExitCode: nil,
                message: current?.message ?? "运行中"
            )
        }

        if let privilegedProcess, privilegedProcess.launchPlan.kernel == targetKernel, processExists(privilegedProcess.pid) {
            let current = statusSnapshots[targetKernel]
            return KernelStatusSnapshot(
                kernel: targetKernel,
                phase: .running,
                processIdentifier: privilegedProcess.pid,
                binaryURL: privilegedProcess.launchPlan.binaryURL,
                configurationURL: privilegedProcess.launchPlan.configurationURL,
                launchedAt: current?.launchedAt ?? privilegedProcess.launchedAt,
                lastExitCode: nil,
                message: current?.message ?? "运行中（管理员模式）"
            )
        }

        return statusSnapshots[targetKernel] ?? .idle(for: targetKernel)
    }

    func recentOutputLines(for kernel: KernelType? = nil) -> [String] {
        let targetKernel = kernel ?? activeProcess?.launchPlan.kernel ?? selectedKernel
        return recentOutput[targetKernel] ?? []
    }

    private func mergedEnvironment(with overrides: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
    }

    private func beginCapturingOutput(for kernel: KernelType, from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                return
            }

            let text = String(decoding: data, as: UTF8.self)

            Task {
                await self?.appendOutput(text, for: kernel)
            }
        }
    }

    private func appendOutput(_ text: String, for kernel: KernelType) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.isEmpty == false }

        guard lines.isEmpty == false else {
            return
        }

        var buffer = recentOutput[kernel] ?? []
        buffer.append(contentsOf: lines)

        if buffer.count > 200 {
            buffer.removeFirst(buffer.count - 200)
        }

        recentOutput[kernel] = buffer

        Task {
            await FluxBarLogService.shared.recordKernelOutput(lines, kernel: kernel)
        }
    }

    private func handleTermination(for kernel: KernelType, processIdentifier: Int32, exitCode: Int32) {
        if let activeProcess, activeProcess.process.processIdentifier == processIdentifier {
            activeProcess.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            activeProcess.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.activeProcess = nil
        } else if statusSnapshots[kernel]?.processIdentifier != processIdentifier {
            return
        }

        statusSnapshots[kernel] = KernelStatusSnapshot(
            kernel: kernel,
            phase: exitCode == 0 ? .stopped : .failed,
            processIdentifier: nil,
            binaryURL: statusSnapshots[kernel]?.binaryURL,
            configurationURL: statusSnapshots[kernel]?.configurationURL,
            launchedAt: statusSnapshots[kernel]?.launchedAt,
            lastExitCode: exitCode,
            message: exitCode == 0 ? "进程已退出" : "进程异常退出 (\(exitCode))"
        )

        Task {
            await FluxBarLogService.shared.record(
                source: kernel == .mihomo ? .mihomo : .smart,
                level: exitCode == 0 ? .info : .error,
                message: exitCode == 0 ? "\(kernel.displayName) 进程已退出" : "\(kernel.displayName) 进程异常退出 (\(exitCode))"
            )
        }
    }

    private func waitForStartupStability(of process: Process) async -> Bool {
        for _ in 0..<3 {
            if process.isRunning == false {
                return false
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return process.isRunning
    }

    private func waitForProcessExit(
        _ process: Process,
        checks: Int,
        intervalNanoseconds: UInt64
    ) async -> Bool {
        for _ in 0..<checks where process.isRunning {
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }

        return process.isRunning == false
    }

    private func forceTerminate(_ process: Process) {
        guard process.isRunning else {
            return
        }

        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func startupFailureMessage(for kernel: KernelType, exitCode: Int32, fallback: String?) -> String {
        let recentLines = (recentOutput[kernel] ?? []).suffix(3).joined(separator: " | ")

        if recentLines.isEmpty == false {
            return "启动后立即退出 (\(exitCode))：\(recentLines)"
        }

        if let fallback, fallback.isEmpty == false {
            return fallback
        }

        return "启动后立即退出 (\(exitCode))"
    }

    private func shouldUsePrivilegedLaunch(for launchPlan: KernelLaunchPlan) -> Bool {
        guard launchPlan.kernel == .mihomo else {
            return false
        }

        return RuntimeConfigurationInspector.inspect(configurationURL: launchPlan.configurationURL).tun.enabled
    }

    private func launchPrivilegedKernel(with launchPlan: KernelLaunchPlan) async throws -> PrivilegedKernelProcess {
        let logsRoot = try FluxBarStorageDirectories.logsRoot(fileManager: fileManager)
        let stdoutURL = logsRoot.appendingPathComponent("\(launchPlan.kernel.rawValue)-tun.stdout.log")
        let stderrURL = logsRoot.appendingPathComponent("\(launchPlan.kernel.rawValue)-tun.stderr.log")

        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let command = privilegedLaunchCommand(
            binaryURL: launchPlan.binaryURL,
            arguments: launchPlan.arguments,
            workingDirectoryURL: launchPlan.workingDirectoryURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL
        )
        let output = try runAppleScriptCommand(command)

        guard
            let firstLine = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.isEmpty == false }),
            let pid = Int32(firstLine),
            processExists(pid)
        else {
            throw TUNError.startFailed("未能获取管理员模式启动后的有效 PID")
        }

        return PrivilegedKernelProcess(
            pid: pid,
            launchPlan: launchPlan,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            launchedAt: Date()
        )
    }

    private func stopPrivilegedKernel(_ privilegedProcess: PrivilegedKernelProcess) async throws {
        let pid = privilegedProcess.pid

        if processExists(pid) == false {
            return
        }

        let command = """
        /bin/kill -TERM \(pid) >/dev/null 2>&1 || true
        /bin/sleep 1
        if /bin/kill -0 \(pid) >/dev/null 2>&1; then
          /bin/kill -KILL \(pid) >/dev/null 2>&1 || true
        fi
        """

        _ = try runAppleScriptCommand(command)

        for _ in 0..<20 where processExists(pid) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if processExists(pid) {
            throw TUNError.stopFailed("管理员模式内核进程未能退出")
        }
    }

    private func runAppleScriptCommand(_ shellCommand: String) throws -> String {
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

    private func privilegedLaunchCommand(
        binaryURL: URL,
        arguments: [String],
        workingDirectoryURL: URL?,
        stdoutURL: URL,
        stderrURL: URL
    ) -> String {
        let executable = shellQuoted(binaryURL.path)
        let argumentString = arguments.map(shellQuoted).joined(separator: " ")
        let workingDirectory = shellQuoted((workingDirectoryURL ?? binaryURL.deletingLastPathComponent()).path)
        let stdoutPath = shellQuoted(stdoutURL.path)
        let stderrPath = shellQuoted(stderrURL.path)

        return """
        cd \(workingDirectory)
        \(executable)\(argumentString.isEmpty ? "" : " \(argumentString)") >> \(stdoutPath) 2>> \(stderrPath) & echo $!
        """
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
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

    private func launchError(for kernel: KernelType, underlying: String) -> KernelError {
        if underlying.contains("管理员") || underlying.contains("privilege") || underlying.contains("User canceled") {
            return .launchFailed(kernel, underlying: TUNError.privilegedOperationRequired(underlying).localizedDescription)
        }

        return .launchFailed(kernel, underlying: underlying)
    }

    private func logTUNConfigurationIfNeeded(for kernel: KernelType, configurationURL: URL?) async {
        guard let configurationURL else {
            return
        }

        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL)
        guard runtimeConfiguration.tun.enabled else {
            return
        }

        let stack = runtimeConfiguration.tun.stack ?? "system"
        let dnsHijackCount = runtimeConfiguration.tun.dnsHijackCount
        await FluxBarLogService.shared.record(
            source: kernel == .mihomo ? .mihomo : .smart,
            level: .info,
            message: "检测到 TUN 配置已启用，stack=\(stack)，dns-hijack=\(dnsHijackCount)。当前采用 mihomo 内置 TUN + 管理员授权启动链路。"
        )
    }
}
