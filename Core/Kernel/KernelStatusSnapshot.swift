import Foundation

enum KernelLifecyclePhase: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed
}

struct KernelStatusSnapshot: Sendable {
    let kernel: KernelType
    let phase: KernelLifecyclePhase
    let processIdentifier: Int32?
    let binaryURL: URL?
    let configurationURL: URL?
    let launchedAt: Date?
    let lastExitCode: Int32?
    let message: String?

    nonisolated var isRunning: Bool {
        phase == .running
    }

    nonisolated static func idle(for kernel: KernelType, message: String? = nil) -> KernelStatusSnapshot {
        KernelStatusSnapshot(
            kernel: kernel,
            phase: .stopped,
            processIdentifier: nil,
            binaryURL: nil,
            configurationURL: nil,
            launchedAt: nil,
            lastExitCode: nil,
            message: message
        )
    }
}
