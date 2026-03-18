import Foundation
import SwiftUI

@MainActor
final class FluxBarDashboardSummaryStore: ObservableObject {
    @Published private(set) var strategyGroupCount = FluxBarConfigurationSupport.strategyGroupCount(from: FluxBarDefaultConfigurationLocator.locate())
    @Published private(set) var activeConnectionCount = 0
    @Published private(set) var uploadRateText = "--"
    @Published private(set) var downloadRateText = "--"
    @Published private(set) var uploadTotalText = "累计 --"
    @Published private(set) var downloadTotalText = "累计 --"

    private var metadataTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    deinit {
        metadataTask?.cancel()
        trafficTask?.cancel()
        connectionTask?.cancel()
    }

    func startSyncLoop() {
        guard metadataTask == nil else {
            return
        }

        metadataTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.refreshNow()

            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled {
                    break
                }
                await self.refreshNow()
            }
        }

        trafficTask = Task { [weak self] in
            guard let self else {
                return
            }

            let stream = await FluxBarRealtimeHub.shared.subscribeTraffic()
            for await snapshot in stream {
                if Task.isCancelled {
                    break
                }
                await self.consumeTrafficSnapshot(snapshot)
            }
        }

        connectionTask = Task { [weak self] in
            guard let self else {
                return
            }

            let stream = await FluxBarRealtimeHub.shared.subscribeConnections()
            for await snapshot in stream {
                if Task.isCancelled {
                    break
                }
                await self.consumeConnectionSnapshot(snapshot)
            }
        }
    }

    func stopSyncLoop() {
        metadataTask?.cancel()
        metadataTask = nil
        trafficTask?.cancel()
        trafficTask = nil
        connectionTask?.cancel()
        connectionTask = nil
    }

    func refreshNow() async {
        let kernelStatus = await KernelManager.shared.runningStatus()
        let configurationURL = kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        strategyGroupCount = FluxBarConfigurationSupport.strategyGroupCount(from: configurationURL)
    }

    private func consumeTrafficSnapshot(_ snapshot: RealtimeTrafficSnapshot) async {
        if snapshot.updatedAt == nil || snapshot.statusMessage.contains("未运行") || snapshot.statusMessage.contains("未配置") {
            uploadRateText = "--"
            downloadRateText = "--"
            uploadTotalText = "累计 --"
            downloadTotalText = "累计 --"
            return
        }

        uploadRateText = Self.trafficRateString(snapshot.upBytesPerSecond)
        downloadRateText = Self.trafficRateString(snapshot.downBytesPerSecond)
        uploadTotalText = "累计 \(Self.trafficTotalString(snapshot.upTotalBytes))"
        downloadTotalText = "累计 \(Self.trafficTotalString(snapshot.downTotalBytes))"
    }

    private func consumeConnectionSnapshot(_ snapshot: RealtimeConnectionSnapshot) async {
        if snapshot.statusMessage.contains("未运行") || snapshot.statusMessage.contains("未配置") {
            activeConnectionCount = 0
            return
        }

        activeConnectionCount = snapshot.activeConnections.count
    }

    private static func trafficRateString(_ value: Double) -> String {
        if value >= 1_048_576 {
            return String(format: "%.2f MB/s", value / 1_048_576)
        }
        if value >= 1_024 {
            return String(format: "%.2f KB/s", value / 1_024)
        }
        return String(format: "%.0f B/s", value)
    }

    private static func trafficTotalString(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_099_511_627_776 {
            return String(format: "%.1f TB", value / 1_099_511_627_776)
        }
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        }
        if value >= 1_024 {
            return String(format: "%.1f KB", value / 1_024)
        }
        return "\(bytes) B"
    }
}
