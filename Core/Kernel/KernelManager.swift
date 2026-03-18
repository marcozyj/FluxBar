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
    private var controllerHealthCache: [KernelType: (checkedAt: Date, isReachable: Bool, message: String?)]

    private struct ListeningProcessInfo: Sendable {
        let pid: Int32
        let port: Int
        let command: String
    }

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
        self.controllerHealthCache = [:]

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

    func selectKernel(_ kernel: KernelType) async -> KernelStatusSnapshot {
        selectedKernel = kernel
        return await runningStatus(for: kernel)
    }

    func start(_ request: KernelStartRequest) async throws -> KernelStatusSnapshot {
        if privilegedProcess == nil, let restored = helperBackedProcess(for: request.kernel) {
            privilegedProcess = restored
        }
        if let activeProcess, activeProcess.process.isRunning {
            if activeProcess.launchPlan.kernel == request.kernel {
                return await runningStatus(for: request.kernel)
            }

            _ = await stop()
        } else if let privilegedProcess, processExists(privilegedProcess.pid) {
            if privilegedProcess.launchPlan.kernel == request.kernel {
                return await runningStatus(for: request.kernel)
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
                let validatedSnapshot = await validatedRunningSnapshot(from: runningSnapshot, forceRefresh: true)
                statusSnapshots[request.kernel] = validatedSnapshot

                if validatedSnapshot.phase != .running {
                    do {
                        try await stopPrivilegedKernel(privilegedProcess)
                    } catch {
                        await FluxBarLogService.shared.record(
                            source: request.kernel == .mihomo ? .mihomo : .smart,
                            level: .warning,
                            message: "管理员模式启动后回滚失败：\(error.localizedDescription)"
                        )
                    }
                    self.privilegedProcess = nil
                    throw KernelError.launchFailed(request.kernel, underlying: validatedSnapshot.message ?? "controller 不可用")
                }

                await FluxBarLogService.shared.record(
                    source: request.kernel == .mihomo ? .mihomo : .smart,
                    level: .info,
                    message: "\(request.kernel.displayName) 已以管理员模式启动，PID \(privilegedProcess.pid)"
                )
                return validatedSnapshot
            }

            let portReleaseResult = await ensureConfiguredPortsReleased(
                configurationURL: launchPlan.configurationURL,
                expectedBinaryURL: launchPlan.binaryURL
            )
            if portReleaseResult.isReleased == false {
                throw KernelError.launchFailed(request.kernel, underlying: portReleaseResult.message ?? "端口占用：9090 或 7890 未释放")
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
        let validatedSnapshot = await validatedRunningSnapshot(from: runningSnapshot, forceRefresh: true)
        statusSnapshots[request.kernel] = validatedSnapshot

        if validatedSnapshot.phase != .running {
            if process.isRunning {
                process.terminate()
                _ = await waitForProcessExit(process, checks: 10, intervalNanoseconds: 100_000_000)
            }
            activeProcess?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            activeProcess?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            throw KernelError.launchFailed(request.kernel, underlying: validatedSnapshot.message ?? "controller 不可用")
        }

        await FluxBarLogService.shared.record(
            source: request.kernel == .mihomo ? .mihomo : .smart,
            level: .info,
            message: "\(request.kernel.displayName) 已启动，PID \(process.processIdentifier)"
        )

        return validatedSnapshot
    }

    func stop() async -> KernelStatusSnapshot {
        let kernel = activeProcess?.launchPlan.kernel ?? privilegedProcess?.launchPlan.kernel ?? selectedKernel

        if privilegedProcess == nil, let restored = helperBackedProcess(for: kernel) {
            privilegedProcess = restored
        }

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

            let portReleaseResult = await ensureConfiguredPortsReleased(
                configurationURL: privilegedProcess.launchPlan.configurationURL,
                expectedBinaryURL: privilegedProcess.launchPlan.binaryURL
            )
            if portReleaseResult.isReleased == false {
                let failedSnapshot = KernelStatusSnapshot(
                    kernel: kernel,
                    phase: .failed,
                    processIdentifier: nil,
                    binaryURL: privilegedProcess.launchPlan.binaryURL,
                    configurationURL: privilegedProcess.launchPlan.configurationURL,
                    launchedAt: privilegedProcess.launchedAt,
                    lastExitCode: nil,
                    message: portReleaseResult.message ?? "端口占用：9090 或 7890 未释放"
                )
                statusSnapshots[kernel] = failedSnapshot
                await FluxBarLogService.shared.record(
                    source: kernel == .mihomo ? .mihomo : .smart,
                    level: .error,
                    message: "\(kernel.displayName) 已停止，但端口未释放：\(portReleaseResult.message ?? "9090/7890")"
                )
                self.privilegedProcess = nil
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

        let portReleaseResult = await ensureConfiguredPortsReleased(
            configurationURL: activeProcess.launchPlan.configurationURL,
            expectedBinaryURL: activeProcess.launchPlan.binaryURL
        )
        if portReleaseResult.isReleased == false {
            let failedSnapshot = KernelStatusSnapshot(
                kernel: kernel,
                phase: .failed,
                processIdentifier: nil,
                binaryURL: activeProcess.launchPlan.binaryURL,
                configurationURL: activeProcess.launchPlan.configurationURL,
                launchedAt: nil,
                lastExitCode: activeProcess.process.terminationStatus,
                message: portReleaseResult.message ?? "端口占用：9090 或 7890 未释放"
            )
            statusSnapshots[kernel] = failedSnapshot
            await FluxBarLogService.shared.record(
                source: kernel == .mihomo ? .mihomo : .smart,
                level: .error,
                message: "\(kernel.displayName) 已停止，但端口未释放：\(portReleaseResult.message ?? "9090/7890")"
            )
            return failedSnapshot
        }

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

    func hasActiveKernelProcess(for kernel: KernelType? = nil) -> Bool {
        let targetKernel = kernel ?? activeProcess?.launchPlan.kernel ?? privilegedProcess?.launchPlan.kernel ?? selectedKernel

        if let activeProcess, activeProcess.launchPlan.kernel == targetKernel, activeProcess.process.isRunning {
            return true
        }

        if privilegedProcess == nil, let restored = helperBackedProcess(for: targetKernel) {
            privilegedProcess = restored
        }

        if let privilegedProcess, privilegedProcess.launchPlan.kernel == targetKernel, processExists(privilegedProcess.pid) {
            return true
        }

        return false
    }

    func isRunningInPrivilegedMode(for kernel: KernelType? = nil) -> Bool {
        let targetKernel = kernel ?? activeProcess?.launchPlan.kernel ?? privilegedProcess?.launchPlan.kernel ?? selectedKernel

        if privilegedProcess == nil, let restored = helperBackedProcess(for: targetKernel) {
            privilegedProcess = restored
        }

        guard
            let privilegedProcess,
            privilegedProcess.launchPlan.kernel == targetKernel
        else {
            return false
        }

        return processExists(privilegedProcess.pid)
    }

    func runningStatus(for kernel: KernelType? = nil) async -> KernelStatusSnapshot {
        let targetKernel = kernel ?? activeProcess?.launchPlan.kernel ?? privilegedProcess?.launchPlan.kernel ?? selectedKernel

        if privilegedProcess == nil, let restored = helperBackedProcess(for: targetKernel) {
            privilegedProcess = restored
        }

        if let activeProcess, activeProcess.launchPlan.kernel == targetKernel, activeProcess.process.isRunning {
            let current = statusSnapshots[targetKernel]
            let snapshot = KernelStatusSnapshot(
                kernel: targetKernel,
                phase: .running,
                processIdentifier: activeProcess.process.processIdentifier,
                binaryURL: activeProcess.launchPlan.binaryURL,
                configurationURL: activeProcess.launchPlan.configurationURL,
                launchedAt: current?.launchedAt ?? Date(),
                lastExitCode: nil,
                message: current?.message ?? "运行中"
            )
            let validated = await validatedRunningSnapshot(from: snapshot)
            statusSnapshots[targetKernel] = validated
            return validated
        }

        if let privilegedProcess, privilegedProcess.launchPlan.kernel == targetKernel, processExists(privilegedProcess.pid) {
            let current = statusSnapshots[targetKernel]
            let snapshot = KernelStatusSnapshot(
                kernel: targetKernel,
                phase: .running,
                processIdentifier: privilegedProcess.pid,
                binaryURL: privilegedProcess.launchPlan.binaryURL,
                configurationURL: privilegedProcess.launchPlan.configurationURL,
                launchedAt: current?.launchedAt ?? privilegedProcess.launchedAt,
                lastExitCode: nil,
                message: current?.message ?? "运行中（管理员模式）"
            )
            let validated = await validatedRunningSnapshot(from: snapshot)
            statusSnapshots[targetKernel] = validated
            return validated
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
        let portReleaseResult = await ensureConfiguredPortsReleased(
            configurationURL: launchPlan.configurationURL,
            expectedBinaryURL: launchPlan.binaryURL
        )
        if portReleaseResult.isReleased == false {
            throw KernelError.launchFailed(launchPlan.kernel, underlying: portReleaseResult.message ?? "端口占用：9090 或 7890 未释放")
        }

        let status = try await PrivilegedTUNHelperService.shared.startKernel(with: launchPlan)

        guard let pid = status.pid else {
            throw TUNError.startFailed("helper/service 未返回有效 PID")
        }

        return PrivilegedKernelProcess(
            pid: pid,
            launchPlan: launchPlan,
            stdoutURL: URL(fileURLWithPath: status.stdoutPath ?? "/dev/null"),
            stderrURL: URL(fileURLWithPath: status.stderrPath ?? "/dev/null"),
            launchedAt: status.launchedAt ?? Date()
        )
    }

    private func stopPrivilegedKernel(_ privilegedProcess: PrivilegedKernelProcess) async throws {
        _ = try await PrivilegedTUNHelperService.shared.stopKernel()
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

    private func waitForConfiguredPortsToRelease(configurationURL: URL?) async -> Bool {
        let ports = configuredPorts(from: configurationURL)
        guard ports.isEmpty == false else {
            return true
        }

        for _ in 0..<40 {
            if ports.allSatisfy({ isListeningOnPort($0) == false }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return ports.allSatisfy { isListeningOnPort($0) == false }
    }

    private func ensureConfiguredPortsReleased(
        configurationURL: URL?,
        expectedBinaryURL: URL?
    ) async -> (isReleased: Bool, message: String?) {
        if await waitForConfiguredPortsToRelease(configurationURL: configurationURL) {
            return (true, nil)
        }

        let ports = configuredPorts(from: configurationURL)
        let listenersBeforeCleanup = listeningProcesses(on: ports)
        let reclaimed = await reclaimListeningProcesses(
            listenersBeforeCleanup,
            expectedBinaryURL: expectedBinaryURL
        )

        if reclaimed, await waitForConfiguredPortsToRelease(configurationURL: configurationURL) {
            return (true, nil)
        }

        let listeners = listeningProcesses(on: ports)
        let detail = listeners.isEmpty
            ? "端口占用：\(ports.map(String.init).joined(separator: "/")) 未释放"
            : "端口占用：\(listeners.map { "\($0.port)(PID \($0.pid))" }.joined(separator: "，"))"
        return (false, detail)
    }

    private func configuredPorts(from configurationURL: URL?) -> [Int] {
        guard
            let configurationURL,
            let content = try? String(contentsOf: configurationURL, encoding: .utf8)
        else {
            return [7890, 9090]
        }

        var ports = Set<Int>()
        ports.insert(scalarIntValue(for: "mixed-port", in: content) ?? 7890)

        if let externalController = scalarStringValue(for: "external-controller", in: content),
           let controllerPort = externalController.split(separator: ":").last.flatMap({ Int($0) }) {
            ports.insert(controllerPort)
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

    private func isListeningOnPort(_ port: Int) -> Bool {
        if lsofReportsListening(on: port) {
            return true
        }

        return netstatReportsListening(on: port)
    }

    private func lsofReportsListening(on port: Int) -> Bool {
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

    private func netstatReportsListening(on port: Int) -> Bool {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-an", "-p", "tcp"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return false
            }

            let output = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let targetPort = ".\(port)"
            for line in output.split(whereSeparator: \.isNewline) {
                let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized.isEmpty == false, normalized.contains("LISTEN") else {
                    continue
                }

                let columns = normalized.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 4 else {
                    continue
                }

                let localAddress = String(columns[3])
                if localAddress.hasSuffix(targetPort) || localAddress.hasSuffix(":\(port)") {
                    return true
                }
            }
        } catch {
            return false
        }

        return false
    }

    private func listeningProcesses(on ports: [Int]) -> [ListeningProcessInfo] {
        var results: [ListeningProcessInfo] = []
        for port in ports {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continue
                }

                let output = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let pids = output
                    .split(whereSeparator: \.isNewline)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

                for pid in pids {
                    results.append(
                        ListeningProcessInfo(
                            pid: pid,
                            port: port,
                            command: commandLine(for: pid)
                        )
                    )
                }
            } catch {
                continue
            }
        }
        return results
    }

    private func commandLine(for pid: Int32) -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            return String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private func reclaimListeningProcesses(
        _ listeners: [ListeningProcessInfo],
        expectedBinaryURL: URL?
    ) async -> Bool {
        let reclaimable = listeners.filter { listener in
            isReclaimableListeningProcess(listener, expectedBinaryURL: expectedBinaryURL)
        }

        guard reclaimable.isEmpty == false else {
            return false
        }

        for listener in reclaimable {
            await FluxBarLogService.shared.record(
                source: .mihomo,
                level: .warning,
                message: "检测到残留监听进程 PID \(listener.pid) 占用 \(listener.port)，正在尝试回收"
            )
            _ = Darwin.kill(listener.pid, SIGTERM)
        }

        try? await Task.sleep(nanoseconds: 800_000_000)

        for listener in reclaimable where processExists(listener.pid) {
            _ = Darwin.kill(listener.pid, SIGKILL)
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        return true
    }

    private func isReclaimableListeningProcess(_ listener: ListeningProcessInfo, expectedBinaryURL: URL?) -> Bool {
        let command = listener.command.lowercased()

        if let expectedBinaryURL {
            let expectedPath = expectedBinaryURL.path.lowercased()
            if command.contains(expectedPath) {
                return true
            }
        }

        if command.contains("fluxbar-mihomo-runtime.yaml") || command.contains("/library/privilegedhelpertools/dev.fluxbar.tun-helper") {
            return true
        }

        return false
    }

    private func helperBackedProcess(for kernel: KernelType) -> PrivilegedKernelProcess? {
        guard kernel == .mihomo,
              let status = PrivilegedTUNHelperService.readInstalledStatus(),
              status.isRunning,
              let pid = status.pid,
              processExists(pid),
              let binaryPath = status.binaryPath else {
            return nil
        }

        let launchPlan = KernelLaunchPlan(
            kernel: kernel,
            binaryURL: URL(fileURLWithPath: binaryPath),
            configurationURL: status.configurationPath.map(URL.init(fileURLWithPath:)),
            workingDirectoryURL: status.workingDirectoryPath.map(URL.init(fileURLWithPath:)),
            arguments: [],
            environment: [:]
        )

        return PrivilegedKernelProcess(
            pid: pid,
            launchPlan: launchPlan,
            stdoutURL: URL(fileURLWithPath: status.stdoutPath ?? "/dev/null"),
            stderrURL: URL(fileURLWithPath: status.stderrPath ?? "/dev/null"),
            launchedAt: status.launchedAt ?? Date()
        )
    }

    private func validatedRunningSnapshot(from snapshot: KernelStatusSnapshot, forceRefresh: Bool = false) async -> KernelStatusSnapshot {
        guard snapshot.phase == .running, snapshot.kernel == .mihomo else {
            return snapshot
        }

        guard let configurationURL = snapshot.configurationURL else {
            return snapshot
        }

        let health = await controllerHealth(
            for: snapshot.kernel,
            configurationURL: configurationURL,
            processIdentifier: snapshot.processIdentifier,
            forceRefresh: forceRefresh
        )
        guard health.isReachable else {
            if let processIdentifier = snapshot.processIdentifier, processExists(processIdentifier) {
                return KernelStatusSnapshot(
                    kernel: snapshot.kernel,
                    phase: .running,
                    processIdentifier: snapshot.processIdentifier,
                    binaryURL: snapshot.binaryURL,
                    configurationURL: snapshot.configurationURL,
                    launchedAt: snapshot.launchedAt,
                    lastExitCode: snapshot.lastExitCode,
                    message: degradedRunningMessage(configurationURL: configurationURL, underlying: health.message)
                )
            }

            return KernelStatusSnapshot(
                kernel: snapshot.kernel,
                phase: .failed,
                processIdentifier: snapshot.processIdentifier,
                binaryURL: snapshot.binaryURL,
                configurationURL: snapshot.configurationURL,
                launchedAt: snapshot.launchedAt,
                lastExitCode: snapshot.lastExitCode,
                message: health.message ?? "controller 不可用"
            )
        }

        return KernelStatusSnapshot(
            kernel: snapshot.kernel,
            phase: .running,
            processIdentifier: snapshot.processIdentifier,
            binaryURL: snapshot.binaryURL,
            configurationURL: snapshot.configurationURL,
            launchedAt: snapshot.launchedAt,
            lastExitCode: snapshot.lastExitCode,
            message: health.message ?? snapshot.message
        )
    }

    private func degradedRunningMessage(configurationURL: URL, underlying: String?) -> String {
        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL)
        let baseMessage = runtimeConfiguration.tun.enabled ? "运行中（TUN，Controller 初始化中）" : "运行中（Controller 初始化中）"
        guard let underlying, underlying.isEmpty == false else {
            return baseMessage
        }
        return "\(baseMessage)：\(underlying)"
    }

    private func controllerHealth(
        for kernel: KernelType,
        configurationURL: URL,
        processIdentifier: Int32?,
        forceRefresh: Bool = false
    ) async -> (isReachable: Bool, message: String?) {
        if forceRefresh == false,
           let cache = controllerHealthCache[kernel],
           Date().timeIntervalSince(cache.checkedAt) < 1 {
            return (cache.isReachable, cache.message)
        }

        guard let context = FluxBarConfigurationSupport.controllerContext(from: configurationURL) else {
            let message = "Controller 未配置"
            controllerHealthCache[kernel] = (Date(), false, message)
            return (false, message)
        }

        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL)
        let maxAttempts: Int
        let retryDelayNanoseconds: UInt64
        if runtimeConfiguration.tun.enabled {
            maxAttempts = forceRefresh ? 8 : 1
            retryDelayNanoseconds = 250_000_000
        } else {
            maxAttempts = forceRefresh ? 3 : 1
            retryDelayNanoseconds = 120_000_000
        }
        let client = MihomoControllerClient(configuration: context.configuration)

        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                _ = try await client.fetchVersion()
                let message = snapshotMessageForReachableController(configurationURL: configurationURL)
                controllerHealthCache[kernel] = (Date(), true, message)
                return (true, message)
            } catch {
                lastError = error

                guard attempt < maxAttempts, Task.isCancelled == false else {
                    break
                }

                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        let message = controllerFailureMessage(
            configurationURL: configurationURL,
            processIdentifier: processIdentifier,
            underlying: lastError?.localizedDescription ?? "未知错误"
        )
        controllerHealthCache[kernel] = (Date(), false, message)
        return (false, message)
    }

    private func snapshotMessageForReachableController(configurationURL: URL) -> String {
        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL)
        return runtimeConfiguration.tun.enabled ? "运行中（TUN）" : "运行中"
    }

    private func controllerFailureMessage(configurationURL: URL, processIdentifier: Int32?, underlying: String) -> String {
        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL)
        let stderrHint = currentFailureHint(for: processIdentifier, configurationURL: configurationURL)
        let combined = [underlying, stderrHint].compactMap { $0 }.joined(separator: " | ")

        if combined.localizedCaseInsensitiveContains("address already in use") || combined.localizedCaseInsensitiveContains("bind:") {
            return "端口占用：请检查 9090 或 7890 是否已被其他进程占用"
        }

        if combined.localizedCaseInsensitiveContains("operation not permitted") {
            return runtimeConfiguration.tun.enabled ? "TUN 启动失败：缺少系统权限或 helper/service 未正确接管" : "内核启动失败：权限不足"
        }

        if combined.localizedCaseInsensitiveContains("parse config error") {
            return "运行配置无效：\(combined)"
        }

        return "Controller 不可达：\(combined)"
    }

    private func currentFailureHint(for processIdentifier: Int32?, configurationURL: URL?) -> String? {
        guard let kernel = configurationURL.flatMap({ _ in KernelType.mihomo }) else {
            return nil
        }

        let outputHint = (recentOutput[kernel] ?? []).suffix(3).joined(separator: " | ")
        if outputHint.isEmpty == false {
            return outputHint
        }

        if let privilegedProcess, privilegedProcess.pid == processIdentifier {
            let stderrText = (try? String(contentsOf: privilegedProcess.stderrURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stderrText, stderrText.isEmpty == false {
                return stderrText
            }
        }

        return nil
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
