import Foundation

enum FluxBarPreferences {
    private static let didInitializeDefaultsKey = "app.didInitializeDefaults"

    static func bool(for key: String, fallback: Bool) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return fallback
        }

        return defaults.bool(forKey: key)
    }

    static func string(for key: String, fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static func set(_ value: Bool, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func set(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func hasValue(for key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    static var didInitializeDefaults: Bool {
        bool(for: didInitializeDefaultsKey, fallback: false)
    }

    static func markDefaultsInitialized() {
        set(true, for: didInitializeDefaultsKey)
    }

    static func initializeDefaultsIfNeeded() {
        guard didInitializeDefaults == false else {
            return
        }

        if hasValue(for: "settings.autoLaunch") == false {
            set(false, for: "settings.autoLaunch")
        }
        if hasValue(for: "settings.coreAutoStart") == false {
            set(true, for: "settings.coreAutoStart")
        }
        if hasValue(for: "settings.systemProxyEnabled") == false {
            set(false, for: "settings.systemProxyEnabled")
        }
        if hasValue(for: "settings.allowLan") == false {
            set(false, for: "settings.allowLan")
        }
        if hasValue(for: "settings.ipv6") == false {
            set(false, for: "settings.ipv6")
        }
        if hasValue(for: "settings.selectedKernel") == false {
            set(KernelType.mihomo.rawValue, for: "settings.selectedKernel")
        }

        markDefaultsInitialized()
    }

    static var selectedKernel: KernelType {
        get {
            KernelType(rawValue: string(for: "settings.selectedKernel", fallback: KernelType.mihomo.rawValue)) ?? .mihomo
        }
        set {
            set(newValue.rawValue, for: "settings.selectedKernel")
        }
    }

    static var coreAutoStartEnabled: Bool {
        bool(for: "settings.coreAutoStart", fallback: true)
    }
}
