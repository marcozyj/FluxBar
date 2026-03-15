import Foundation

struct RoutingRulesCacheSnapshot: Codable, Sendable {
    let configurationSignature: String
    let generatedAt: Date
    let rules: [FluxBarResolvedRoutingRuleRecord]
}

struct ProviderLatencyCacheEntry: Codable, Sendable {
    let key: String
    let providerID: String?
    let nodeID: String
    let nodeName: String
    let delay: Int
    let measuredAt: Date
    let targetURL: String
}

struct ProviderLatencyCacheSnapshot: Codable, Sendable {
    let configurationSignature: String
    let updatedAt: Date
    let entries: [ProviderLatencyCacheEntry]
}

enum RoutingRulesCacheStore {
    private static func cacheURL(fileManager: FileManager = .default) throws -> URL {
        try FluxBarStorageDirectories.stateRoot(fileManager: fileManager)
            .appendingPathComponent("routing-rules-cache.json", isDirectory: false)
    }

    static func load(configurationURL: URL?) -> RoutingRulesCacheSnapshot? {
        guard
            let configurationSignature = FluxBarConfigurationSupport.configurationSignature(for: configurationURL),
            let cacheURL = try? cacheURL(),
            let data = try? Data(contentsOf: cacheURL),
            let snapshot = try? JSONDecoder().decode(RoutingRulesCacheSnapshot.self, from: data),
            snapshot.configurationSignature == configurationSignature
        else {
            return nil
        }

        return snapshot
    }

    @discardableResult
    static func refresh(configurationURL: URL?) -> RoutingRulesCacheSnapshot? {
        guard
            let configurationURL,
            let configurationSignature = FluxBarConfigurationSupport.configurationSignature(for: configurationURL)
        else {
            return nil
        }

        let snapshot = RoutingRulesCacheSnapshot(
            configurationSignature: configurationSignature,
            generatedAt: Date(),
            rules: FluxBarConfigurationSupport.resolveRoutingRules(from: configurationURL)
        )

        guard let cacheURL = try? cacheURL() else {
            return snapshot
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            return snapshot
        }

        return snapshot
    }
}

enum ProviderLatencyCacheStore {
    private static func cacheURL(fileManager: FileManager = .default) throws -> URL {
        try FluxBarStorageDirectories.stateRoot(fileManager: fileManager)
            .appendingPathComponent("provider-latency-cache.json", isDirectory: false)
    }

    static func load(configurationURL: URL?) -> ProviderLatencyCacheSnapshot? {
        guard
            let configurationSignature = FluxBarConfigurationSupport.configurationSignature(for: configurationURL),
            let cacheURL = try? cacheURL(),
            let data = try? Data(contentsOf: cacheURL),
            let snapshot = try? JSONDecoder().decode(ProviderLatencyCacheSnapshot.self, from: data),
            snapshot.configurationSignature == configurationSignature
        else {
            return nil
        }

        return snapshot
    }

    static func providerLatencies(configurationURL: URL?) -> [String: [String: Int]] {
        let entries = load(configurationURL: configurationURL)?.entries ?? []
        return entries.reduce(into: [String: [String: Int]]()) { partialResult, entry in
            guard let providerID = entry.providerID else {
                return
            }
            partialResult[providerID, default: [:]][entry.nodeID] = entry.delay
        }
    }

    static func nameLatencies(configurationURL: URL?) -> [String: Int] {
        let entries = load(configurationURL: configurationURL)?.entries ?? []
        let sorted = entries.sorted { $0.measuredAt > $1.measuredAt }
        var result: [String: Int] = [:]
        for entry in sorted {
            if result[entry.nodeName] == nil {
                result[entry.nodeName] = entry.delay
            }
        }
        return result
    }

    static func replaceProviderLatencies(
        providerID: String,
        nodes: [FluxBarProviderNodeSnapshot],
        latenciesByNodeID: [String: Int],
        targetURL: String,
        configurationURL: URL?
    ) {
        guard let configurationSignature = FluxBarConfigurationSupport.configurationSignature(for: configurationURL) else {
            return
        }

        var existingEntries = load(configurationURL: configurationURL)?.entries ?? []
        existingEntries.removeAll { $0.providerID == providerID }

        let measuredAt = Date()
        let newEntries = nodes.compactMap { node -> ProviderLatencyCacheEntry? in
            guard let delay = latenciesByNodeID[node.id] else {
                return nil
            }

            return ProviderLatencyCacheEntry(
                key: "\(providerID)::\(node.id)",
                providerID: providerID,
                nodeID: node.id,
                nodeName: node.name,
                delay: delay,
                measuredAt: measuredAt,
                targetURL: targetURL
            )
        }

        persist(
            snapshot: ProviderLatencyCacheSnapshot(
                configurationSignature: configurationSignature,
                updatedAt: measuredAt,
                entries: existingEntries + newEntries
            )
        )
    }

    static func mergeNamedLatencies(
        _ latencies: [String: Int],
        targetURL: String,
        configurationURL: URL?
    ) {
        guard let configurationSignature = FluxBarConfigurationSupport.configurationSignature(for: configurationURL) else {
            return
        }

        var existingEntries = load(configurationURL: configurationURL)?.entries ?? []
        let keys = Set(latencies.keys)
        existingEntries.removeAll { $0.providerID == nil && keys.contains($0.nodeName) }

        let measuredAt = Date()
        let newEntries = latencies.map { name, delay in
            ProviderLatencyCacheEntry(
                key: "strategy::\(name)",
                providerID: nil,
                nodeID: name,
                nodeName: name,
                delay: delay,
                measuredAt: measuredAt,
                targetURL: targetURL
            )
        }

        persist(
            snapshot: ProviderLatencyCacheSnapshot(
                configurationSignature: configurationSignature,
                updatedAt: measuredAt,
                entries: existingEntries + newEntries
            )
        )
    }

    private static func persist(snapshot: ProviderLatencyCacheSnapshot) {
        guard let cacheURL = try? cacheURL() else {
            return
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            return
        }
    }
}

actor FluxBarConfigurationRefreshCoordinator {
    static let shared = FluxBarConfigurationRefreshCoordinator()

    struct RefreshResult: Sendable {
        let providerTotal: Int
        let providerSuccess: Int
        let ruleTotal: Int
        let ruleSuccess: Int
    }

    func refreshAll(configurationURL: URL?) async throws -> RefreshResult {
        guard let configurationURL else {
            return RefreshResult(providerTotal: 0, providerSuccess: 0, ruleTotal: 0, ruleSuccess: 0)
        }

        async let providerRefresh = FluxBarConfigurationSupport.refreshProviders(from: configurationURL)
        async let ruleRefresh = FluxBarConfigurationSupport.refreshRuleProviders(from: configurationURL)
        let providerResult = try await providerRefresh
        let ruleResult = try await ruleRefresh
        _ = RoutingRulesCacheStore.refresh(configurationURL: configurationURL)

        return RefreshResult(
            providerTotal: providerResult.total,
            providerSuccess: providerResult.success,
            ruleTotal: ruleResult.total,
            ruleSuccess: ruleResult.success
        )
    }
}

actor FluxBarBootstrapCoordinator {
    static let shared = FluxBarBootstrapCoordinator()

    private var didBootstrap = false

    func bootstrapOnLaunchIfNeeded() async {
        guard didBootstrap == false else {
            return
        }
        didBootstrap = true

        guard let configurationURL = FluxBarDefaultConfigurationLocator.locate() else {
            return
        }

        let refreshResult = try? await FluxBarConfigurationRefreshCoordinator.shared.refreshAll(configurationURL: configurationURL)
        _ = RoutingRulesCacheStore.refresh(configurationURL: configurationURL)

        if let refreshResult, refreshResult.providerSuccess > 0 {
            await measureProviderLatenciesIfPossible(configurationURL: configurationURL)
        }

        await MainActor.run {
            NotificationCenter.default.post(name: fluxBarConfigurationDidRefreshNotification, object: nil)
        }
    }

    private func measureProviderLatenciesIfPossible(configurationURL: URL) async {
        let kernelStatus = await KernelManager.shared.runningStatus(for: .mihomo)
        guard kernelStatus.isRunning else {
            return
        }

        guard let context = FluxBarConfigurationSupport.latencyContext(from: configurationURL) else {
            return
        }

        let client = MihomoControllerClient(configuration: context.configuration)
        let providerNodes = FluxBarConfigurationSupport.loadProviderNodesMap(from: configurationURL)

        for (providerID, nodes) in providerNodes where nodes.isEmpty == false {
            let latencies = await withTaskGroup(of: (String, Int?).self, returning: [String: Int].self) { group in
                for node in nodes {
                    group.addTask {
                        do {
                            let delay = try await client.testProxyDelay(
                                named: node.name,
                                targetURL: context.targetURL,
                                timeoutMilliseconds: 2_000
                            )
                            return (node.id, delay)
                        } catch {
                            return (node.id, nil)
                        }
                    }
                }

                var results: [String: Int] = [:]
                for await (id, delay) in group {
                    if let delay {
                        results[id] = delay
                    }
                }
                return results
            }

            ProviderLatencyCacheStore.replaceProviderLatencies(
                providerID: providerID,
                nodes: nodes,
                latenciesByNodeID: latencies,
                targetURL: context.targetURL,
                configurationURL: configurationURL
            )
        }
    }
}
