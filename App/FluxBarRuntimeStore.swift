import Combine
import Foundation
import SwiftUI

@MainActor
final class FluxBarRuntimeStore: ObservableObject {
    @Published private(set) var selectedKernel: KernelType = .mihomo
    @Published private(set) var kernelStatus = KernelStatusSnapshot.idle(for: .mihomo, message: "等待同步")
    @Published private(set) var tunStatus = TUNStatusSnapshot.placeholder
    @Published private(set) var tunConfiguration = RuntimeTUNSnapshot.unavailable
    @Published private(set) var controllerSnapshot = RuntimeControllerSnapshot.unavailable
    @Published private(set) var modeTitle = "未同步"
    @Published private(set) var recentOutputCount = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isApplyingTun = false

    private var syncTask: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshRequestedWhileRunning = false

    deinit {
        syncTask?.cancel()
    }

    func startSyncLoop() {
        guard syncTask == nil else {
            return
        }

        syncTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.selectKernel(FluxBarPreferences.selectedKernel)
            await self.refreshNow()

            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                if Task.isCancelled {
                    break
                }

                await self.refreshNow()
            }
        }
    }

    func stopSyncLoop() {
        syncTask?.cancel()
        syncTask = nil
    }

    func refreshNow() async {
        if isRefreshing {
            refreshRequestedWhileRunning = true
            return
        }

        isRefreshing = true

        repeat {
            refreshRequestedWhileRunning = false

            let kernelStatus = await KernelManager.shared.runningStatus()
            let tunStatus = await TUNManager.shared.refreshStatus()
            let recentOutput = await KernelManager.shared.recentOutputLines(for: kernelStatus.kernel)
            let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: kernelStatus.configurationURL)

            selectedKernel = kernelStatus.kernel
            self.kernelStatus = kernelStatus
            self.tunStatus = tunStatus
            tunConfiguration = runtimeConfiguration.tun
            controllerSnapshot = runtimeConfiguration.controller
            modeTitle = runtimeConfiguration.modeTitle ?? "未配置"
            recentOutputCount = recentOutput.count
            lastSyncedAt = Date()
        } while refreshRequestedWhileRunning

        isRefreshing = false
    }

    func selectKernel(_ kernel: KernelType) async {
        let kernelStatus = await KernelManager.shared.selectKernel(kernel)
        let recentOutput = await KernelManager.shared.recentOutputLines(for: kernel)
        let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: kernelStatus.configurationURL)

        selectedKernel = kernel
        self.kernelStatus = kernelStatus
        tunConfiguration = runtimeConfiguration.tun
        controllerSnapshot = runtimeConfiguration.controller
        modeTitle = runtimeConfiguration.modeTitle ?? "未配置"
        recentOutputCount = recentOutput.count
        lastSyncedAt = Date()
    }

    func applyTUNChange(_ enabled: Bool) async -> TUNStatusSnapshot {
        guard isApplyingTun == false else {
            return tunStatus
        }

        isApplyingTun = true
        tunStatus = tunStatus.transitioning(to: enabled)

        do {
            let result = try await FluxBarRuntimeCoordinator.shared.applyTUNChange(
                enabled: enabled,
                selectedKernel: selectedKernel,
                currentConfigurationURL: kernelStatus.configurationURL
            )
            let runtimeConfiguration = RuntimeConfigurationInspector.inspect(configurationURL: result.configResult.outputURL)
            let recentOutput = await KernelManager.shared.recentOutputLines(for: result.kernel)

            selectedKernel = result.kernel
            kernelStatus = result.kernelStatus
            tunStatus = result.tunStatus
            tunConfiguration = runtimeConfiguration.tun
            controllerSnapshot = runtimeConfiguration.controller
            modeTitle = runtimeConfiguration.modeTitle ?? modeTitle
            recentOutputCount = recentOutput.count
        } catch {
            tunStatus = TUNStatusSnapshot(
                phase: .failed,
                isEnabled: false,
                permissionState: .requiresManualSetup,
                implementationTitle: "mihomo 内置 TUN / helper service",
                statusMessage: error.localizedDescription,
                detailMessage: error.localizedDescription,
                recoveryMessage: "请确认已提供可用配置文件，并且当前使用 mihomo 内核。",
                needsManualSetup: true
            )
        }

        isApplyingTun = false
        lastSyncedAt = Date()

        return tunStatus
    }
}
