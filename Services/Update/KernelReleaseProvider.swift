import Foundation

protocol KernelReleaseProviding: Sendable {
    nonisolated func latestRelease(
        for kernel: KernelType,
        channel: KernelUpdateChannel,
        platform: KernelTargetPlatform
    ) async throws -> KernelReleaseManifest?
}
