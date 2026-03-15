import Foundation

enum KernelError: LocalizedError, Sendable {
    case runtimeUnavailable(KernelType)
    case binaryNotFound(KernelType, searchedPaths: [URL])
    case missingConfiguration(KernelType)
    case launchFailed(KernelType, underlying: String)
    case noPreviousLaunchConfiguration(KernelType)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let kernel):
            return "\(kernel.displayName) 运行时尚未注册"
        case .binaryNotFound(let kernel, let searchedPaths):
            let paths = searchedPaths.map(\.path).joined(separator: "、")
            return "\(kernel.displayName) 内核文件不存在。已检查：\(paths)"
        case .missingConfiguration(let kernel):
            return "\(kernel.displayName) 缺少启动配置文件"
        case .launchFailed(let kernel, let underlying):
            return "\(kernel.displayName) 启动失败：\(underlying)"
        case .noPreviousLaunchConfiguration(let kernel):
            return "\(kernel.displayName) 没有可用于重启的历史启动参数"
        }
    }
}
