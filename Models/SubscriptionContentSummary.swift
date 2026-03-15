import Foundation

struct SubscriptionContentSummary: Codable, Sendable {
    let proxyCount: Int
    let proxyGroupCount: Int
    let ruleProviderCount: Int
    let externalController: String?
    let hasSecret: Bool
    let suggestedName: String?

    nonisolated init(
        proxyCount: Int = 0,
        proxyGroupCount: Int = 0,
        ruleProviderCount: Int = 0,
        externalController: String? = nil,
        hasSecret: Bool = false,
        suggestedName: String? = nil
    ) {
        self.proxyCount = proxyCount
        self.proxyGroupCount = proxyGroupCount
        self.ruleProviderCount = ruleProviderCount
        self.externalController = externalController
        self.hasSecret = hasSecret
        self.suggestedName = suggestedName
    }
}
