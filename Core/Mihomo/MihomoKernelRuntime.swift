import Foundation

struct MihomoKernelRuntime: KernelRuntime {
    nonisolated let kernel: KernelType = .mihomo

    nonisolated init() {}

    nonisolated func makeLaunchPlan(
        from request: KernelStartRequest,
        resolvedBinaryURL: URL
    ) throws -> KernelLaunchPlan {
        let arguments = try request.arguments.isEmpty
            ? defaultArguments(for: request)
            : request.arguments

        return KernelLaunchPlan(
            kernel: kernel,
            binaryURL: resolvedBinaryURL,
            configurationURL: request.configurationURL,
            workingDirectoryURL: request.workingDirectoryURL,
            arguments: arguments,
            environment: request.environment
        )
    }

    nonisolated private func defaultArguments(for request: KernelStartRequest) throws -> [String] {
        guard let configurationURL = request.configurationURL else {
            throw KernelError.missingConfiguration(kernel)
        }

        var arguments = ["-f", configurationURL.path]

        if let workingDirectoryURL = request.workingDirectoryURL {
            arguments.append(contentsOf: ["-d", workingDirectoryURL.path])
        }

        return arguments
    }
}
