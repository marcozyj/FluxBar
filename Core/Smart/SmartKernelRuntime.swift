import Foundation

struct SmartKernelRuntime: KernelRuntime {
    nonisolated let kernel: KernelType = .smart

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

        // Smart 的实际 CLI 细节会在接入真实内核时校准；这里允许调用方覆盖 arguments。
        return ["-f", configurationURL.path]
    }
}
