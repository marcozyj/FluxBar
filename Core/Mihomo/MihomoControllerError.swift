import Foundation

enum MihomoControllerError: LocalizedError, Sendable {
    case invalidControllerAddress(String)
    case invalidRequestPath(String)
    case invalidResponse(path: String, statusCode: Int, body: String?)
    case malformedPayload(path: String)
    case missingField(path: String, field: String)
    case websocketClosed(path: String, reason: String)
    case transport(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidControllerAddress(let address):
            return "Mihomo Controller 地址无效：\(address)"
        case .invalidRequestPath(let path):
            return "Mihomo Controller 请求路径无效：\(path)"
        case .invalidResponse(let path, let statusCode, let body):
            if let body, body.isEmpty == false {
                return "Mihomo Controller 请求失败：\(path) (\(statusCode)) \(body)"
            }
            return "Mihomo Controller 请求失败：\(path) (\(statusCode))"
        case .malformedPayload(let path):
            return "Mihomo Controller 返回了无法解析的数据：\(path)"
        case .missingField(let path, let field):
            return "Mihomo Controller 返回缺少必要字段：\(path) -> \(field)"
        case .websocketClosed(let path, let reason):
            return "Mihomo Controller WebSocket 已关闭：\(path) \(reason)"
        case .transport(let path, let message):
            return "Mihomo Controller 传输异常：\(path) \(message)"
        }
    }
}
