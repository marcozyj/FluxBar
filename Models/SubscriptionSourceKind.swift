import Foundation

enum SubscriptionSourceKind: String, Codable, CaseIterable, Sendable {
    case remoteURL
    case localConfig
}
