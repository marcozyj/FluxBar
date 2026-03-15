import Foundation

enum KernelUpdateError: LocalizedError, Sendable {
    case releaseSourceUnavailable(KernelType)
    case noCompatibleAsset(KernelType, platform: String)
    case invalidReleasePayload(KernelType)
    case manifestNotConfigured(KernelType)
    case invalidManifest(String)
    case downloadFailed(URL, underlying: String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case installFailed(KernelType, underlying: String)

    var errorDescription: String? {
        switch self {
        case .releaseSourceUnavailable(let kernel):
            return "\(kernel.displayName) 没有可用的更新源"
        case .noCompatibleAsset(let kernel, let platform):
            return "\(kernel.displayName) 没有匹配当前平台的安装包：\(platform)"
        case .invalidReleasePayload(let kernel):
            return "\(kernel.displayName) 更新源返回了无法识别的数据"
        case .manifestNotConfigured(let kernel):
            return "\(kernel.displayName) 尚未配置更新 manifest"
        case .invalidManifest(let message):
            return "更新 manifest 无效：\(message)"
        case .downloadFailed(let url, let underlying):
            return "下载更新失败：\(url.absoluteString) \(underlying)"
        case .checksumMismatch(let expected, let actual):
            return "更新包校验失败：期望 \(expected)，实际 \(actual)"
        case .extractionFailed(let message):
            return "更新包解压失败：\(message)"
        case .installFailed(let kernel, let underlying):
            return "\(kernel.displayName) 替换安装失败：\(underlying)"
        }
    }
}
