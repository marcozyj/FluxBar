import AppKit
import SwiftUI

final class FluxBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: FluxBarStatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = FluxBarStatusBarController()

        Task {
            await FluxBarFirstLaunchCoordinator.shared.bootstrapIfNeeded()
            await FluxBarKernelLifecycleController.shared.bootstrapOnLaunchIfNeeded()
            if FluxBarPreferences.bool(for: "settings.systemProxyEnabled", fallback: false) {
                let configurationURL = FluxBarDefaultConfigurationLocator.locate()
                _ = await SystemProxyManager.shared.applyProxyState(enabled: true, configurationURL: configurationURL)
            }
            await FluxBarBootstrapCoordinator.shared.bootstrapOnLaunchIfNeeded()
        }
        Task {
            await FluxBarConnectionMonitor.shared.start()
        }
    }
}
