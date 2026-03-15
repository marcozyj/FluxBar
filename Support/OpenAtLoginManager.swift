import Foundation
import ServiceManagement

enum OpenAtLoginManager {
    static func isEnabled() -> Bool {
        guard #available(macOS 13.0, *) else {
            return FluxBarPreferences.bool(for: "settings.autoLaunch", fallback: false)
        }

        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            FluxBarPreferences.set(enabled, for: "settings.autoLaunch")
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            FluxBarPreferences.set(enabled, for: "settings.autoLaunch")
        } catch {
            throw OpenAtLoginError.operationFailed(error.localizedDescription)
        }
    }

    static func syncWithPreference() throws {
        let desiredState = FluxBarPreferences.bool(for: "settings.autoLaunch", fallback: false)

        if isEnabled() != desiredState {
            try setEnabled(desiredState)
        }
    }
}

enum OpenAtLoginError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            return "开机自启设置失败：\(message)"
        }
    }
}
