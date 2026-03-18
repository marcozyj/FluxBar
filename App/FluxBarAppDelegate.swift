import AppKit
import SwiftUI

final class FluxBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: FluxBarStatusBarController?
    private var realtimeLogTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = FluxBarStatusBarController()

        Task {
            await FluxBarFirstLaunchCoordinator.shared.bootstrapIfNeeded()
            await FluxBarKernelLifecycleController.shared.bootstrapOnLaunchIfNeeded()
            await FluxBarBootstrapCoordinator.shared.bootstrapOnLaunchIfNeeded()
            await restorePersistedRuntimeState()
        }
        realtimeLogTask = Task {
            let stream = await FluxBarRealtimeHub.shared.subscribeLogs()
            for await _ in stream {
                if Task.isCancelled {
                    break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        realtimeLogTask?.cancel()
        realtimeLogTask = nil
    }

    private func restorePersistedRuntimeState() async {
        let shouldEnableSystemProxy = FluxBarPreferences.bool(for: "settings.systemProxyEnabled", fallback: false)
        let kernelStatus = await KernelManager.shared.runningStatus()
        let configurationURL = kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        _ = await SystemProxyManager.shared.applyProxyState(
            enabled: shouldEnableSystemProxy,
            configurationURL: configurationURL
        )
        if shouldEnableSystemProxy {
            await SystemProxyManager.shared.refreshGuard()
        }
    }
}
