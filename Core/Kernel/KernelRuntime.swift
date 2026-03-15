import Foundation

struct KernelLaunchPlan: Sendable {
    let kernel: KernelType
    let binaryURL: URL
    let configurationURL: URL?
    let workingDirectoryURL: URL?
    let arguments: [String]
    let environment: [String: String]
}

protocol KernelRuntime: Sendable {
    nonisolated var kernel: KernelType { get }

    nonisolated func makeLaunchPlan(
        from request: KernelStartRequest,
        resolvedBinaryURL: URL
    ) throws -> KernelLaunchPlan
}
