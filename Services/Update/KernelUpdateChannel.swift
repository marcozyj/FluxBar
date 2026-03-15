import Foundation

enum KernelUpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case prerelease
}

enum KernelAssetArchiveFormat: String, Codable, Sendable {
    case raw
    case gzip
}

enum KernelArchitecture: String, Codable, Sendable {
    case amd64
    case arm64

    nonisolated static var current: KernelArchitecture {
        #if arch(arm64)
        .arm64
        #else
        .amd64
        #endif
    }
}

struct KernelTargetPlatform: Sendable {
    let operatingSystem: String
    let architecture: KernelArchitecture

    nonisolated init(
        operatingSystem: String = "darwin",
        architecture: KernelArchitecture = .current
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    nonisolated static let current = KernelTargetPlatform()
}
