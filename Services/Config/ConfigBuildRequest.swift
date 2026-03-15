import Foundation

enum ConfigProxyMode: String, Codable, CaseIterable, Sendable {
    case rule
    case global
    case direct
}

enum ConfigLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
    case silent
}

enum ConfigTUNStack: String, Codable, CaseIterable, Sendable {
    case system
    case gvisor
    case mixed
}

struct ConfigTUNOverrides: Codable, Sendable {
    var enabled: Bool?
    var stack: ConfigTUNStack?
    var autoRoute: Bool?
    var autoDetectInterface: Bool?
    var strictRoute: Bool?
    var dnsHijack: [String]?

    nonisolated init(
        enabled: Bool? = nil,
        stack: ConfigTUNStack? = nil,
        autoRoute: Bool? = nil,
        autoDetectInterface: Bool? = nil,
        strictRoute: Bool? = nil,
        dnsHijack: [String]? = nil
    ) {
        self.enabled = enabled
        self.stack = stack
        self.autoRoute = autoRoute
        self.autoDetectInterface = autoDetectInterface
        self.strictRoute = strictRoute
        self.dnsHijack = dnsHijack
    }
}

struct ConfigBuildOverrides: Codable, Sendable {
    var httpPort: Int?
    var socksPort: Int?
    var mixedPort: Int?
    var redirPort: Int?
    var tproxyPort: Int?
    var mode: ConfigProxyMode?
    var allowLAN: Bool?
    var bindAddress: String?
    var logLevel: ConfigLogLevel?
    var ipv6: Bool?
    var externalController: String?
    var secret: String?
    var tunEnabled: Bool?
    var tun: ConfigTUNOverrides?

    nonisolated init(
        httpPort: Int? = nil,
        socksPort: Int? = nil,
        mixedPort: Int? = nil,
        redirPort: Int? = nil,
        tproxyPort: Int? = nil,
        mode: ConfigProxyMode? = nil,
        allowLAN: Bool? = nil,
        bindAddress: String? = nil,
        logLevel: ConfigLogLevel? = nil,
        ipv6: Bool? = nil,
        externalController: String? = nil,
        secret: String? = nil,
        tunEnabled: Bool? = nil,
        tun: ConfigTUNOverrides? = nil
    ) {
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.mixedPort = mixedPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
        self.mode = mode
        self.allowLAN = allowLAN
        self.bindAddress = bindAddress
        self.logLevel = logLevel
        self.ipv6 = ipv6
        self.externalController = externalController
        self.secret = secret
        self.tunEnabled = tunEnabled
        self.tun = tun
    }
}

struct ConfigBuildRequest: Sendable {
    let kernel: KernelType
    let sourceIDs: [UUID]?
    let fallbackConfigurationURL: URL?
    var preferredFileName: String?
    var overrides: ConfigBuildOverrides

    nonisolated init(
        kernel: KernelType,
        sourceIDs: [UUID]? = nil,
        fallbackConfigurationURL: URL? = nil,
        preferredFileName: String? = nil,
        overrides: ConfigBuildOverrides = .init()
    ) {
        self.kernel = kernel
        self.sourceIDs = sourceIDs
        self.fallbackConfigurationURL = fallbackConfigurationURL
        self.preferredFileName = preferredFileName
        self.overrides = overrides
    }
}
