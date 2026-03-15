import Foundation

enum SubscriptionError: LocalizedError, Sendable {
    case invalidRemoteURL(String)
    case unsupportedRemoteScheme(String)
    case duplicateRemoteURL(URL)
    case sourceNotFound(UUID)
    case missingRemoteURL(UUID)
    case localFileUnavailable(String)
    case importFailed(String, underlying: String)
    case updateFailed(UUID, underlying: String)
    case invalidResponse(URL, statusCode: Int)
    case storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL(let value):
            return "订阅地址无效：\(value)"
        case .unsupportedRemoteScheme(let scheme):
            return "订阅地址协议不受支持：\(scheme)"
        case .duplicateRemoteURL(let url):
            return "该订阅地址已存在：\(url.absoluteString)"
        case .sourceNotFound(let id):
            return "未找到订阅源：\(id.uuidString)"
        case .missingRemoteURL(let id):
            return "订阅源缺少远程地址：\(id.uuidString)"
        case .localFileUnavailable(let path):
            return "本地配置文件不可用：\(path)"
        case .importFailed(let path, let underlying):
            return "导入本地配置失败：\(path) \(underlying)"
        case .updateFailed(_, let underlying):
            return "更新订阅失败：\(underlying)"
        case .invalidResponse(let url, let statusCode):
            return "订阅请求失败：\(url.absoluteString) (\(statusCode))"
        case .storageFailure(let message):
            return "订阅存储失败：\(message)"
        }
    }
}
