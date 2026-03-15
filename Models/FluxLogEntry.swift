import Foundation

nonisolated enum FluxLogSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case app
    case mihomo
    case smart
    case subscription
    case update
    case tun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app:
            return "App"
        case .mihomo:
            return "Mihomo"
        case .smart:
            return "Smart"
        case .subscription:
            return "订阅"
        case .update:
            return "更新"
        case .tun:
            return "TUN"
        }
    }

    var tone: FluxTone {
        switch self {
        case .app:
            return .neutral
        case .mihomo, .smart:
            return .accent
        case .subscription:
            return .positive
        case .update:
            return .warning
        case .tun:
            return .critical
        }
    }
}

nonisolated enum FluxLogLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .debug:
            return "调试"
        case .info:
            return "信息"
        case .warning:
            return "警告"
        case .error:
            return "错误"
        }
    }

    var tone: FluxTone {
        switch self {
        case .debug:
            return .neutral
        case .info:
            return .accent
        case .warning:
            return .warning
        case .error:
            return .critical
        }
    }

    nonisolated static func infer(from message: String) -> FluxLogLevel {
        let lowered = message.lowercased()

        if lowered.contains("fatal") || lowered.contains("panic") || lowered.contains("error") || lowered.contains("failed") {
            return .error
        }

        if lowered.contains("warn") || lowered.contains("timeout") || lowered.contains("retry") {
            return .warning
        }

        if lowered.contains("debug") || lowered.contains("trace") {
            return .debug
        }

        return .info
    }
}

nonisolated struct FluxLogEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let source: FluxLogSource
    let level: FluxLogLevel
    let message: String

    nonisolated init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: FluxLogSource,
        level: FluxLogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.message = message
    }
}
