import Foundation

enum TUNError: LocalizedError, Sendable {
    case helperServiceUnavailable
    case helperServiceInstallFailed(String)
    case preferencesLoadFailed(String)
    case preferencesSaveFailed(String)
    case privilegedOperationRequired(String)
    case permissionDenied(String)
    case startFailed(String)
    case stopFailed(String)
    case recoveryFailed(original: String, recovery: String)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .helperServiceUnavailable:
            return "缺少可用的 mihomo TUN helper/service"
        case .helperServiceInstallFailed(let message):
            return "安装 TUN helper/service 失败：\(message)"
        case .preferencesLoadFailed(let message):
            return "读取 TUN 配置失败：\(message)"
        case .preferencesSaveFailed(let message):
            return "保存 TUN 配置失败：\(message)"
        case .privilegedOperationRequired(let message):
            return "TUN 需要管理员权限或 helper/service：\(message)"
        case .permissionDenied(let message):
            return "TUN 权限或能力不可用：\(message)"
        case .startFailed(let message):
            return "启动 TUN 失败：\(message)"
        case .stopFailed(let message):
            return "关闭 TUN 失败：\(message)"
        case .recoveryFailed(let original, let recovery):
            return "TUN 启动失败且恢复未完成：原始错误 \(original)，恢复错误 \(recovery)"
        case .internalFailure(let message):
            return "TUN 内部错误：\(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .helperServiceUnavailable:
            return "请改用 mihomo 内置 TUN 路线，并补充提权 helper/service 的安装与启动流程。"
        case .helperServiceInstallFailed:
            return "请检查 helper/service 的安装路径、launchd 配置和管理员授权。"
        case .preferencesLoadFailed, .preferencesSaveFailed, .permissionDenied, .privilegedOperationRequired:
            return "请检查 helper/service、管理员授权和 TUN 相关系统配置后重试。"
        case .startFailed:
            return "请确认 mihomo 配置中的 tun 段有效，并且 helper/service 已正确安装。"
        case .stopFailed:
            return "请重新加载 helper/service 状态后重试，必要时重启应用。"
        case .recoveryFailed:
            return "请重新初始化 helper/service，并清理上一次失败遗留的 TUN 状态。"
        case .internalFailure:
            return "请查看日志并重新尝试初始化 TUN。"
        }
    }
}
