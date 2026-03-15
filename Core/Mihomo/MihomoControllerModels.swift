import Foundation

enum MihomoLogLevel: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
    case unknown
}

struct MihomoLatencySample: Identifiable, Sendable {
    let id: String
    let timestamp: Date?
    let delay: Int?

    nonisolated init(timestamp: Date?, delay: Int?) {
        self.id = "\(timestamp?.timeIntervalSince1970 ?? 0)-\(delay ?? -1)"
        self.timestamp = timestamp
        self.delay = delay
    }
}

struct MihomoProxyGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    let current: String?
    let all: [String]
    let icon: String?
    let hidden: Bool
    let history: [MihomoLatencySample]
}

struct MihomoProxyNode: Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    let alive: Bool?
    let delay: Int?
    let udpSupported: Bool?
    let provider: String?
    let icon: String?
    let history: [MihomoLatencySample]
}

struct MihomoRule: Identifiable, Sendable {
    let id: String
    let type: String
    let payload: String
    let proxy: String
    let provider: String?
}

struct MihomoConnectionMetadata: Sendable {
    let network: String?
    let type: String?
    let sourceIP: String?
    let sourcePort: Int?
    let destinationIP: String?
    let destinationPort: String?
    let host: String?
    let process: String?
    let processPath: String?
}

struct MihomoConnection: Identifiable, Sendable {
    let id: String
    let uploadBytes: Int64
    let downloadBytes: Int64
    let start: Date?
    let chains: [String]
    let rule: String?
    let rulePayload: String?
    let metadata: MihomoConnectionMetadata
}

struct MihomoConnectionsSnapshot: Sendable {
    let uploadTotalBytes: Int64
    let downloadTotalBytes: Int64
    let connections: [MihomoConnection]
    let memoryBytes: Int64?
}

struct MihomoLogEntry: Identifiable, Sendable {
    let id: UUID
    let level: MihomoLogLevel
    let payload: String
    let timestamp: Date

    nonisolated init(level: MihomoLogLevel, payload: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.level = level
        self.payload = payload
        self.timestamp = timestamp
    }
}

struct MihomoTrafficSnapshot: Sendable {
    let up: Double
    let down: Double
    let upTotal: Int64
    let downTotal: Int64
}

struct MihomoVersionInfo: Sendable {
    let version: String
    let meta: Bool?
    let premium: Bool?
}
