import Foundation

enum FluxBarKernelLifecycleError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "没有找到可用配置文件，无法启动内核"
        }
    }
}

actor FluxBarKernelLifecycleController {
    static let shared = FluxBarKernelLifecycleController()

    private var didRunLaunchBootstrap = false

    func bootstrapOnLaunchIfNeeded() async {
        guard didRunLaunchBootstrap == false else {
            return
        }

        didRunLaunchBootstrap = true
        _ = await KernelManager.shared.selectKernel(FluxBarPreferences.selectedKernel)

        guard FluxBarPreferences.coreAutoStartEnabled else {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "内核自启已关闭，跳过启动时自动拉起内核"
            )
            return
        }

        do {
            _ = try await startOrRestartSelectedKernel(forceRestart: false)
            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "应用启动完成，已自动拉起 \(FluxBarPreferences.selectedKernel.displayName) 内核"
            )
        } catch {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .error,
                message: "应用启动时自动拉起内核失败：\(error.localizedDescription)"
            )
        }
    }

    func startOrRestartSelectedKernel(forceRestart: Bool) async throws -> KernelStatusSnapshot {
        let kernel = FluxBarPreferences.selectedKernel
        _ = await KernelManager.shared.selectKernel(kernel)

        guard let configurationURL = FluxBarDefaultConfigurationLocator.locate() else {
            throw FluxBarKernelLifecycleError.missingConfiguration
        }

        let currentStatus = await KernelManager.shared.runningStatus(for: kernel)
        if forceRestart == false, currentStatus.isRunning {
            return currentStatus
        }

        if currentStatus.isRunning {
            _ = await KernelManager.shared.stop()
        }

        return try await KernelManager.shared.start(
            KernelStartRequest(
                kernel: kernel,
                configurationURL: currentStatus.configurationURL ?? configurationURL,
                workingDirectoryURL: configurationURL.deletingLastPathComponent()
            )
        )
    }
}
