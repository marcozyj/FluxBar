import Foundation

enum SubscriptionUpdateStatus: String, Codable, Sendable {
    case updated
    case unchanged
    case imported
    case failed
}

struct SubscriptionUpdateResult: Sendable {
    let sourceID: UUID
    let sourceName: String
    let status: SubscriptionUpdateStatus
    let updatedAt: Date
    let summary: SubscriptionContentSummary?
    let message: String

    nonisolated init(
        sourceID: UUID,
        sourceName: String,
        status: SubscriptionUpdateStatus,
        updatedAt: Date = Date(),
        summary: SubscriptionContentSummary? = nil,
        message: String
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.status = status
        self.updatedAt = updatedAt
        self.summary = summary
        self.message = message
    }
}
