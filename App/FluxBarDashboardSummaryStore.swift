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

    private var syncTask: Task<Void, Never>?

    deinit {
        syncTask?.cancel()
    }

    func startSyncLoop() {
        guard syncTask == nil else {
            return
        }

        syncTask = Task { [weak self] in
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
    }

    func stopSyncLoop() {
        syncTask?.cancel()
        syncTask = nil
    }

    func refreshNow() async {
        let configurationURL = FluxBarDefaultConfigurationLocator.locate()
        let nextStrategyGroupCount = FluxBarConfigurationSupport.strategyGroupCount(from: configurationURL)

        let monitorSnapshot = await FluxBarConnectionMonitor.shared.snapshot()
        var nextActiveConnectionCount = monitorSnapshot.activeConnectionCount
        var nextUploadRateText = "--"
        var nextDownloadRateText = "--"
        var nextUploadTotalText = "累计 --"
        var nextDownloadTotalText = "累计 --"

        if let context = controllerContext(from: configurationURL),
           let configuration = try? MihomoControllerConfiguration(
                controllerAddress: context.controllerAddress,
                secret: context.secret,
                preferLoopbackAccess: true
           ) {
            let client = MihomoControllerClient(configuration: configuration)

            if let traffic = try? await client.fetchLiveTrafficSnapshot() {
                nextUploadRateText = Self.trafficRateString(traffic.up)
                nextDownloadRateText = Self.trafficRateString(traffic.down)
                nextUploadTotalText = "累计 \(Self.trafficTotalString(traffic.upTotal))"
                nextDownloadTotalText = "累计 \(Self.trafficTotalString(traffic.downTotal))"
            }

            if let connections = try? await client.fetchConnections() {
                nextActiveConnectionCount = connections.connections.count
            }
        }

        strategyGroupCount = nextStrategyGroupCount
        activeConnectionCount = nextActiveConnectionCount
        uploadRateText = nextUploadRateText
        downloadRateText = nextDownloadRateText
        uploadTotalText = nextUploadTotalText
        downloadTotalText = nextDownloadTotalText
    }

    private func controllerContext(from configurationURL: URL?) -> (controllerAddress: String, secret: String?)? {
        guard
            let configurationURL,
            let text = try? String(contentsOf: configurationURL, encoding: .utf8),
            let controllerAddress = scalarValue(for: "external-controller", in: text),
            controllerAddress.isEmpty == false
        else {
            return nil
        }

        return (controllerAddress, scalarValue(for: "secret", in: text))
    }

    private func scalarValue(for key: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.hasPrefix("#") == false
                    && line.hasPrefix("\(key):")
            }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
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
