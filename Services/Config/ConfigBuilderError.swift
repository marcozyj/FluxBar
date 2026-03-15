import Foundation

enum ConfigBuilderError: LocalizedError, Sendable {
    case noEnabledSources
    case fallbackConfigurationUnreadable(String)
    case sourcePayloadMissing(UUID)
    case sourcePayloadUnreadable(String)
    case outputWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEnabledSources:
            return "没有可用于生成配置的启用订阅源"
        case .fallbackConfigurationUnreadable(let path):
            return "备用配置文件无法读取：\(path)"
        case .sourcePayloadMissing(let sourceID):
            return "订阅源缺少可用配置内容：\(sourceID.uuidString)"
        case .sourcePayloadUnreadable(let name):
            return "订阅源内容无法读取：\(name)"
        case .outputWriteFailed(let path):
            return "最终配置文件写入失败：\(path)"
        }
    }
}
