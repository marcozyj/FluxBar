import Foundation

let fluxBarConnectionMonitorDidUpdate = Notification.Name("FluxBarConnectionMonitorDidUpdate")

struct FluxBarConnectionRecord: Identifiable, Sendable {
    let id: String
    let connection: MihomoConnection
    let firstSeenAt: Date
    let lastSeenAt: Date
}

struct FluxBarConnectionMonitorSnapshot: Sendable {
    let records: [FluxBarConnectionRecord]
    let hitCounts: [String: Int]
    let statusMessage: String
    let activeConnectionCount: Int
    let updatedAt: Date?

    static let empty = FluxBarConnectionMonitorSnapshot(
        records: [],
        hitCounts: [:],
        statusMessage: "等待连接监控",
        activeConnectionCount: 0,
        updatedAt: nil
    )
}

actor FluxBarConnectionMonitor {
    static let shared = FluxBarConnectionMonitor()

    private struct MutableRecord {
        var connection: MihomoConnection
        var firstSeenAt: Date
        var lastSeenAt: Date
    }

    private var monitorTask: Task<Void, Never>?
    private var records: [String: MutableRecord] = [:]
    private var hitCounts: [String: Int] = [:]
    private var statusMessage = "等待连接监控"
    private var activeConnectionCount = 0
    private var updatedAt: Date?

    func start() {
        guard monitorTask == nil else {
            return
        }

        monitorTask = Task {
            await runLoop()
        }
    }

    func snapshot() -> FluxBarConnectionMonitorSnapshot {
        FluxBarConnectionMonitorSnapshot(
            records: records
                .map { key, value in
                    FluxBarConnectionRecord(
                        id: key,
                        connection: value.connection,
                        firstSeenAt: value.firstSeenAt,
                        lastSeenAt: value.lastSeenAt
                    )
                }
                .sorted { $0.lastSeenAt > $1.lastSeenAt },
            hitCounts: hitCounts,
            statusMessage: statusMessage,
            activeConnectionCount: activeConnectionCount,
            updatedAt: updatedAt
        )
    }

    private func runLoop() async {
        while Task.isCancelled == false {
            await pollOnce()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func pollOnce() async {
        let kernelStatus = await KernelManager.shared.runningStatus()
        guard kernelStatus.isRunning else {
            pruneExpiredRecords(referenceDate: Date())
            activeConnectionCount = 0
            statusMessage = kernelStatus.message ?? "内核未运行"
            updatedAt = Date()
            await publishUpdate()
            return
        }

        let configurationURL = kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        guard let context = FluxBarConfigurationSupport.controllerContext(from: configurationURL) else {
            pruneExpiredRecords(referenceDate: Date())
            activeConnectionCount = 0
            statusMessage = "Controller 未配置"
            updatedAt = Date()
            await publishUpdate()
            return
        }

        let client = MihomoControllerClient(configuration: context.configuration)

        do {
            let snapshot = try await client.fetchConnections()
            let now = Date()
            activeConnectionCount = snapshot.connections.count
            statusMessage = snapshot.connections.isEmpty ? "暂无活动连接" : "连接监控运行中"
            updatedAt = now

            for connection in snapshot.connections {
                if var record = records[connection.id] {
                    record.connection = connection
                    record.lastSeenAt = now
                    records[connection.id] = record
                } else {
                    records[connection.id] = MutableRecord(
                        connection: connection,
                        firstSeenAt: now,
                        lastSeenAt: now
                    )
                    incrementHitCount(for: connection)
                }
            }

            pruneExpiredRecords(referenceDate: now)
            await publishUpdate()
        } catch {
            pruneExpiredRecords(referenceDate: Date())
            activeConnectionCount = records.count
            statusMessage = "Controller 暂时不可用"
            updatedAt = Date()
            await publishUpdate()
        }
    }

    private func incrementHitCount(for connection: MihomoConnection) {
        if let payload = connection.rulePayload, payload.isEmpty == false {
            hitCounts[payload, default: 0] += 1
        }

        if let rule = connection.rule, rule.isEmpty == false {
            hitCounts[rule, default: 0] += 1
        }
    }

    private func pruneExpiredRecords(referenceDate: Date) {
        let ttl: TimeInterval = 120
        records = records.filter { _, record in
            referenceDate.timeIntervalSince(record.lastSeenAt) <= ttl
        }
    }

    private func publishUpdate() async {
        await MainActor.run {
            NotificationCenter.default.post(name: fluxBarConnectionMonitorDidUpdate, object: nil)
        }
    }
}
