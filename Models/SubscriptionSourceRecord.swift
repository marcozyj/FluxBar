import Foundation

struct SubscriptionSourceRecord: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    let kind: SubscriptionSourceKind
    var remoteURL: URL?
    var localFilePath: String?
    var localFileBookmark: Data?
    var storedFileName: String?
    var isEnabled: Bool
    var order: Int
    let createdAt: Date
    var lastUpdatedAt: Date?
    var lastContentHash: String?
    var lastResponseETag: String?
    var lastResponseLastModified: String?
    var lastErrorMessage: String?
    var contentSummary: SubscriptionContentSummary

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        kind: SubscriptionSourceKind,
        remoteURL: URL? = nil,
        localFilePath: String? = nil,
        localFileBookmark: Data? = nil,
        storedFileName: String? = nil,
        isEnabled: Bool = true,
        order: Int,
        createdAt: Date = Date(),
        lastUpdatedAt: Date? = nil,
        lastContentHash: String? = nil,
        lastResponseETag: String? = nil,
        lastResponseLastModified: String? = nil,
        lastErrorMessage: String? = nil,
        contentSummary: SubscriptionContentSummary = .init()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.remoteURL = remoteURL
        self.localFilePath = localFilePath
        self.localFileBookmark = localFileBookmark
        self.storedFileName = storedFileName
        self.isEnabled = isEnabled
        self.order = order
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastContentHash = lastContentHash
        self.lastResponseETag = lastResponseETag
        self.lastResponseLastModified = lastResponseLastModified
        self.lastErrorMessage = lastErrorMessage
        self.contentSummary = contentSummary
    }
}
