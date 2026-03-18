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

struct RealtimeTrafficSnapshot: Sendable {
    let upBytesPerSecond: Double
    let downBytesPerSecond: Double
    let upTotalBytes: Int64
    let downTotalBytes: Int64
    let statusMessage: String
    let updatedAt: Date?

    nonisolated static let unavailable = RealtimeTrafficSnapshot(
        upBytesPerSecond: 0,
        downBytesPerSecond: 0,
        upTotalBytes: 0,
        downTotalBytes: 0,
        statusMessage: "等待流量监控",
        updatedAt: nil
    )
}

struct RealtimeActiveConnection: Identifiable, Sendable {
    let id: String
    let connection: MihomoConnection
    let firstSeenAt: Date
    let lastSeenAt: Date
    let curUploadBytes: Int64
    let curDownloadBytes: Int64
}

struct RealtimeClosedConnection: Identifiable, Sendable {
    let id: String
    let connection: MihomoConnection
    let firstSeenAt: Date
    let lastSeenAt: Date
    let closedAt: Date
}

struct RealtimeConnectionSnapshot: Sendable {
    let uploadTotalBytes: Int64
    let downloadTotalBytes: Int64
    let memoryBytes: Int64?
    let activeConnections: [RealtimeActiveConnection]
    let closedConnections: [RealtimeClosedConnection]
    let statusMessage: String
    let updatedAt: Date?

    nonisolated static let unavailable = RealtimeConnectionSnapshot(
        uploadTotalBytes: 0,
        downloadTotalBytes: 0,
        memoryBytes: nil,
        activeConnections: [],
        closedConnections: [],
        statusMessage: "等待连接监控",
        updatedAt: nil
    )
}

struct RealtimeLogSnapshot: Sendable {
    let entries: [MihomoLogEntry]
    let statusMessage: String
    let updatedAt: Date?

    nonisolated static let unavailable = RealtimeLogSnapshot(
        entries: [],
        statusMessage: "等待日志流",
        updatedAt: nil
    )
}

actor FluxBarRealtimeHub {
    static let shared = FluxBarRealtimeHub()

    private struct ActiveConnectionState {
        var firstSeenAt: Date
        var lastSeenAt: Date
        var connection: MihomoConnection
    }

    private let reconnectDelayNanoseconds: UInt64 = 1_000_000_000
    private let maxClosedConnections = 500
    private let maxControllerLogEntries = 240

    private var trafficSnapshot = RealtimeTrafficSnapshot.unavailable
    private var connectionSnapshot = RealtimeConnectionSnapshot.unavailable
    private var logSnapshot = RealtimeLogSnapshot.unavailable

    private var activeConnectionStates: [String: ActiveConnectionState] = [:]
    private var closedConnections: [RealtimeClosedConnection] = []
    private var controllerLogs: [MihomoLogEntry] = []

    private var trafficSubscribers: [UUID: AsyncStream<RealtimeTrafficSnapshot>.Continuation] = [:]
    private var connectionSubscribers: [UUID: AsyncStream<RealtimeConnectionSnapshot>.Continuation] = [:]
    private var logSubscribers: [UUID: AsyncStream<RealtimeLogSnapshot>.Continuation] = [:]

    private var trafficTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?

    func subscribeTraffic() -> AsyncStream<RealtimeTrafficSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            trafficSubscribers[id] = continuation
            continuation.yield(trafficSnapshot)
            continuation.onTermination = { _ in
                Task { await self.removeTrafficSubscriber(id) }
            }
            startTrafficStreamIfNeeded()
        }
    }

    func subscribeConnections() -> AsyncStream<RealtimeConnectionSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            connectionSubscribers[id] = continuation
            continuation.yield(connectionSnapshot)
            continuation.onTermination = { _ in
                Task { await self.removeConnectionSubscriber(id) }
            }
            startConnectionStreamIfNeeded()
        }
    }

    func subscribeLogs() -> AsyncStream<RealtimeLogSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            logSubscribers[id] = continuation
            continuation.yield(logSnapshot)
            continuation.onTermination = { _ in
                Task { await self.removeLogSubscriber(id) }
            }
            startLogStreamIfNeeded()
        }
    }

    func latestTrafficSnapshot() -> RealtimeTrafficSnapshot {
        trafficSnapshot
    }

    func latestConnectionSnapshot() -> RealtimeConnectionSnapshot {
        connectionSnapshot
    }

    func latestLogSnapshot() -> RealtimeLogSnapshot {
        logSnapshot
    }

    private func startTrafficStreamIfNeeded() {
        guard trafficTask == nil, trafficSubscribers.isEmpty == false else {
            return
        }

        trafficTask = Task {
            await runTrafficLoop()
        }
    }

    private func startConnectionStreamIfNeeded() {
        guard connectionTask == nil, connectionSubscribers.isEmpty == false else {
            return
        }

        connectionTask = Task {
            await runConnectionLoop()
        }
    }

    private func startLogStreamIfNeeded() {
        guard logTask == nil, logSubscribers.isEmpty == false else {
            return
        }

        logTask = Task {
            await runLogLoop()
        }
    }

    private func stopTrafficStreamIfNeeded() {
        guard trafficSubscribers.isEmpty else {
            return
        }

        trafficTask?.cancel()
        trafficTask = nil
    }

    private func stopConnectionStreamIfNeeded() {
        guard connectionSubscribers.isEmpty else {
            return
        }

        connectionTask?.cancel()
        connectionTask = nil
    }

    private func stopLogStreamIfNeeded() {
        guard logSubscribers.isEmpty else {
            return
        }

        logTask?.cancel()
        logTask = nil
    }

    private func removeTrafficSubscriber(_ id: UUID) {
        trafficSubscribers.removeValue(forKey: id)
        stopTrafficStreamIfNeeded()
    }

    private func removeConnectionSubscriber(_ id: UUID) {
        connectionSubscribers.removeValue(forKey: id)
        stopConnectionStreamIfNeeded()
    }

    private func removeLogSubscriber(_ id: UUID) {
        logSubscribers.removeValue(forKey: id)
        stopLogStreamIfNeeded()
    }

    private func runTrafficLoop() async {
        while Task.isCancelled == false {
            let runtime = await runtimeContext()
            guard runtime.kernelStatus.isRunning else {
                updateTrafficUnavailable(message: runtime.kernelStatus.message ?? "内核未运行")
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            guard let context = runtime.controllerContext else {
                updateTrafficUnavailable(message: "Controller 未配置")
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            let client = MihomoControllerClient(configuration: context.configuration)
            do {
                let stream = try await client.streamTraffic()
                for try await snapshot in stream {
                    if Task.isCancelled {
                        break
                    }

                    trafficSnapshot = RealtimeTrafficSnapshot(
                        upBytesPerSecond: snapshot.up,
                        downBytesPerSecond: snapshot.down,
                        upTotalBytes: snapshot.upTotal,
                        downTotalBytes: snapshot.downTotal,
                        statusMessage: "流量监控运行中",
                        updatedAt: Date()
                    )
                    publishTrafficSnapshot()
                }
            } catch {
                if let fallback = try? await client.fetchTrafficSnapshot() {
                    trafficSnapshot = RealtimeTrafficSnapshot(
                        upBytesPerSecond: fallback.up,
                        downBytesPerSecond: fallback.down,
                        upTotalBytes: fallback.upTotal,
                        downTotalBytes: fallback.downTotal,
                        statusMessage: "流量流暂时不可用，已切换兜底快照",
                        updatedAt: Date()
                    )
                    publishTrafficSnapshot()
                } else {
                    updateTrafficUnavailable(message: "流量流暂时不可用")
                }
            }

            if Task.isCancelled {
                break
            }

            try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
        }
    }

    private func runConnectionLoop() async {
        while Task.isCancelled == false {
            let runtime = await runtimeContext()
            guard runtime.kernelStatus.isRunning else {
                activeConnectionStates.removeAll()
                connectionSnapshot = RealtimeConnectionSnapshot(
                    uploadTotalBytes: 0,
                    downloadTotalBytes: 0,
                    memoryBytes: nil,
                    activeConnections: [],
                    closedConnections: closedConnections,
                    statusMessage: runtime.kernelStatus.message ?? "内核未运行",
                    updatedAt: Date()
                )
                publishConnectionSnapshot()
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            guard let context = runtime.controllerContext else {
                connectionSnapshot = RealtimeConnectionSnapshot(
                    uploadTotalBytes: 0,
                    downloadTotalBytes: 0,
                    memoryBytes: nil,
                    activeConnections: [],
                    closedConnections: closedConnections,
                    statusMessage: "Controller 未配置",
                    updatedAt: Date()
                )
                publishConnectionSnapshot()
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            let client = MihomoControllerClient(configuration: context.configuration)
            do {
                let stream = try await client.streamConnections(intervalMilliseconds: 1_000)
                for try await snapshot in stream {
                    if Task.isCancelled {
                        break
                    }

                    consumeConnectionSnapshot(snapshot)
                }
            } catch {
                if let fallback = try? await client.fetchConnections() {
                    consumeConnectionSnapshot(fallback)
                    connectionSnapshot = RealtimeConnectionSnapshot(
                        uploadTotalBytes: connectionSnapshot.uploadTotalBytes,
                        downloadTotalBytes: connectionSnapshot.downloadTotalBytes,
                        memoryBytes: connectionSnapshot.memoryBytes,
                        activeConnections: connectionSnapshot.activeConnections,
                        closedConnections: connectionSnapshot.closedConnections,
                        statusMessage: "连接流暂时不可用，已切换兜底快照",
                        updatedAt: Date()
                    )
                    publishConnectionSnapshot()
                } else {
                    connectionSnapshot = RealtimeConnectionSnapshot(
                        uploadTotalBytes: connectionSnapshot.uploadTotalBytes,
                        downloadTotalBytes: connectionSnapshot.downloadTotalBytes,
                        memoryBytes: connectionSnapshot.memoryBytes,
                        activeConnections: connectionSnapshot.activeConnections,
                        closedConnections: closedConnections,
                        statusMessage: "连接流暂时不可用",
                        updatedAt: Date()
                    )
                    publishConnectionSnapshot()
                }
            }

            if Task.isCancelled {
                break
            }

            try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
        }
    }

    private func runLogLoop() async {
        while Task.isCancelled == false {
            let runtime = await runtimeContext()
            guard runtime.kernelStatus.isRunning else {
                logSnapshot = RealtimeLogSnapshot(
                    entries: controllerLogs,
                    statusMessage: runtime.kernelStatus.message ?? "内核未运行",
                    updatedAt: Date()
                )
                publishLogSnapshot()
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            guard let context = runtime.controllerContext else {
                logSnapshot = RealtimeLogSnapshot(
                    entries: controllerLogs,
                    statusMessage: "Controller 未配置",
                    updatedAt: Date()
                )
                publishLogSnapshot()
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
                continue
            }

            let client = MihomoControllerClient(configuration: context.configuration)
            var pendingPersistEntries: [MihomoLogEntry] = []
            var lastPersistAt = Date.distantPast
            do {
                let stream = try await client.streamLogs(
                    level: configuredLogLevel(
                        configurationURL: runtime.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
                    )
                )
                for try await entry in stream {
                    if Task.isCancelled {
                        break
                    }

                    controllerLogs.append(entry)
                    if controllerLogs.count > maxControllerLogEntries {
                        controllerLogs.removeFirst(controllerLogs.count - maxControllerLogEntries)
                    }

                    logSnapshot = RealtimeLogSnapshot(
                        entries: controllerLogs,
                        statusMessage: "日志流运行中",
                        updatedAt: Date()
                    )
                    publishLogSnapshot()

                    pendingPersistEntries.append(entry)
                    let now = Date()
                    if pendingPersistEntries.count >= 20 || now.timeIntervalSince(lastPersistAt) >= 0.35 {
                        await FluxBarLogService.shared.recordControllerLogs(pendingPersistEntries)
                        pendingPersistEntries.removeAll(keepingCapacity: true)
                        lastPersistAt = now
                    }
                }

                if pendingPersistEntries.isEmpty == false {
                    await FluxBarLogService.shared.recordControllerLogs(pendingPersistEntries)
                }
            } catch {
                if pendingPersistEntries.isEmpty == false {
                    await FluxBarLogService.shared.recordControllerLogs(pendingPersistEntries)
                }
                logSnapshot = RealtimeLogSnapshot(
                    entries: controllerLogs,
                    statusMessage: "日志流暂时不可用",
                    updatedAt: Date()
                )
                publishLogSnapshot()
            }

            if Task.isCancelled {
                break
            }

            try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
        }
    }

    private func updateTrafficUnavailable(message: String) {
        trafficSnapshot = RealtimeTrafficSnapshot(
            upBytesPerSecond: 0,
            downBytesPerSecond: 0,
            upTotalBytes: trafficSnapshot.upTotalBytes,
            downTotalBytes: trafficSnapshot.downTotalBytes,
            statusMessage: message,
            updatedAt: Date()
        )
        publishTrafficSnapshot()
    }

    private func consumeConnectionSnapshot(_ snapshot: MihomoConnectionsSnapshot) {
        let now = Date()
        var nextStates: [String: ActiveConnectionState] = [:]
        var active: [RealtimeActiveConnection] = []

        for connection in snapshot.connections {
            let previous = activeConnectionStates[connection.id]
            let firstSeen = previous?.firstSeenAt ?? now
            let curUpload = max(0, connection.uploadBytes - (previous?.connection.uploadBytes ?? connection.uploadBytes))
            let curDownload = max(0, connection.downloadBytes - (previous?.connection.downloadBytes ?? connection.downloadBytes))

            nextStates[connection.id] = ActiveConnectionState(
                firstSeenAt: firstSeen,
                lastSeenAt: now,
                connection: connection
            )
            active.append(
                RealtimeActiveConnection(
                    id: connection.id,
                    connection: connection,
                    firstSeenAt: firstSeen,
                    lastSeenAt: now,
                    curUploadBytes: curUpload,
                    curDownloadBytes: curDownload
                )
            )
        }

        for (id, previousState) in activeConnectionStates where nextStates[id] == nil {
            closedConnections.append(
                RealtimeClosedConnection(
                    id: id,
                    connection: previousState.connection,
                    firstSeenAt: previousState.firstSeenAt,
                    lastSeenAt: previousState.lastSeenAt,
                    closedAt: now
                )
            )
        }

        if closedConnections.count > maxClosedConnections {
            closedConnections.removeFirst(closedConnections.count - maxClosedConnections)
        }

        activeConnectionStates = nextStates
        connectionSnapshot = RealtimeConnectionSnapshot(
            uploadTotalBytes: snapshot.uploadTotalBytes,
            downloadTotalBytes: snapshot.downloadTotalBytes,
            memoryBytes: snapshot.memoryBytes,
            activeConnections: active,
            closedConnections: closedConnections,
            statusMessage: active.isEmpty ? "暂无活动连接" : "连接监控运行中",
            updatedAt: now
        )
        publishConnectionSnapshot()
    }

    private func publishTrafficSnapshot() {
        for (_, continuation) in trafficSubscribers {
            continuation.yield(trafficSnapshot)
        }
    }

    private func publishConnectionSnapshot() {
        for (_, continuation) in connectionSubscribers {
            continuation.yield(connectionSnapshot)
        }
    }

    private func publishLogSnapshot() {
        for (_, continuation) in logSubscribers {
            continuation.yield(logSnapshot)
        }
    }

    private func runtimeContext() async -> (kernelStatus: KernelStatusSnapshot, controllerContext: FluxBarControllerContext?) {
        let kernelStatus = await KernelManager.shared.runningStatus()
        let configurationURL = kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        let controllerContext = FluxBarConfigurationSupport.controllerContext(from: configurationURL)
        return (kernelStatus, controllerContext)
    }

    private func configuredLogLevel(configurationURL: URL?) -> MihomoLogLevel {
        guard
            let configurationURL,
            let text = try? String(contentsOf: configurationURL, encoding: .utf8)
        else {
            return .info
        }

        let rawValue = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.hasPrefix("#") == false && line.hasPrefix("log-level:")
            }
            .map { line in
                line
                    .dropFirst("log-level:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .lowercased()
            } ?? ConfigLogLevel.info.rawValue

        switch rawValue {
        case ConfigLogLevel.debug.rawValue:
            return .debug
        case ConfigLogLevel.warning.rawValue:
            return .warning
        case ConfigLogLevel.error.rawValue:
            return .error
        case ConfigLogLevel.silent.rawValue:
            return .error
        default:
            return .info
        }
    }
}
