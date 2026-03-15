import Foundation
import SwiftUI

private enum NetworkProtocolFilter: String, CaseIterable {
    case all = "全部协议"
    case tcp = "TCP"
    case udp = "UDP"

    var transport: String? {
        switch self {
        case .all:
            return nil
        case .tcp:
            return "TCP"
        case .udp:
            return "UDP"
        }
    }
}

private struct NetworkRuleResolution {
    let ruleSetName: String
    let strategyGroupName: String
}

private enum NetworkRoutingResolver {
    static func resolve(connection: MihomoConnection, mapping: FluxBarRouteStrategyMap) -> NetworkRuleResolution {
        let ruleSetName = normalizedRuleSetName(connection: connection)

        if let payload = connection.rulePayload,
           let strategy = mapping.ruleSetStrategies[payload] {
            return NetworkRuleResolution(
                ruleSetName: ruleSetName,
                strategyGroupName: strategy
            )
        }

        if let rule = connection.rule?.uppercased(),
           let payload = connection.rulePayload,
           let strategy = mapping.inlineStrategies["\(rule):\(payload)"] {
            return NetworkRuleResolution(
                ruleSetName: ruleSetName,
                strategyGroupName: strategy
            )
        }

        if let matchStrategy = mapping.inlineStrategies["MATCH"], (connection.rule ?? "").uppercased() == "MATCH" {
            return NetworkRuleResolution(
                ruleSetName: ruleSetName,
                strategyGroupName: matchStrategy
            )
        }

        let fallbackStrategy = (connection.chains.first?.isEmpty == false ? connection.chains.first : nil)
            ?? fallbackRoute(from: connection)

        return NetworkRuleResolution(
            ruleSetName: ruleSetName,
            strategyGroupName: fallbackStrategy
        )
    }

    private static func normalizedRuleSetName(connection: MihomoConnection) -> String {
        if let payload = connection.rulePayload, payload.isEmpty == false {
            return payload
        }

        if let rule = connection.rule, rule.isEmpty == false {
            return rule
        }

        return "--"
    }

    private static func fallbackRoute(from connection: MihomoConnection) -> String {
        if let rule = connection.rule, rule.uppercased() == "DIRECT" {
            return "直连"
        }
        return connection.rule ?? "直连"
    }
}

private struct NetworkConnection: Identifiable {
    let id: String
    let title: String
    let transport: String
    let uploadBytes: Int64
    let downloadBytes: Int64
    let ruleSetName: String
    let strategyGroupName: String
    let actualRoute: String
    let icon: String
    let time: String

    var ruleTone: FluxTone {
        if ruleSetName == "--" {
            return .warning
        }

        if ruleSetName.localizedCaseInsensitiveContains("google") || ruleSetName.localizedCaseInsensitiveContains("github") {
            return .accent
        }

        if strategyGroupName.localizedCaseInsensitiveContains("直连") {
            return .neutral
        }

        return .positive
    }

    static func make(from connection: MihomoConnection, mapping: FluxBarRouteStrategyMap) -> NetworkConnection {
        let resolution = NetworkRoutingResolver.resolve(connection: connection, mapping: mapping)
        let transport = (connection.metadata.network ?? connection.metadata.type ?? "--").uppercased()
        let actualRoute = connection.chains.isEmpty
            ? resolution.strategyGroupName
            : connection.chains.joined(separator: " → ")
        let title = displayTitle(for: connection)

        return NetworkConnection(
            id: connection.id,
            title: title,
            transport: transport,
            uploadBytes: connection.uploadBytes,
            downloadBytes: connection.downloadBytes,
            ruleSetName: resolution.ruleSetName,
            strategyGroupName: resolution.strategyGroupName,
            actualRoute: actualRoute,
            icon: icon(for: title, process: connection.metadata.process),
            time: timestampText(from: connection.start)
        )
    }

    private static func displayTitle(for connection: MihomoConnection) -> String {
        if let host = normalizedNonEmpty(connection.metadata.host) {
            return host
        }

        if let processPath = normalizedNonEmpty(connection.metadata.processPath) {
            let fileName = URL(fileURLWithPath: processPath).lastPathComponent
            if fileName.isEmpty == false {
                return fileName
            }
        }

        if let process = normalizedNonEmpty(connection.metadata.process) {
            return process
        }

        if let destination = normalizedNonEmpty(connection.metadata.destinationIP) {
            return destination
        }

        let source = normalizedNonEmpty(connection.metadata.sourceIP).map { "\($0):\(connection.metadata.sourcePort ?? 0)" } ?? "--"
        let destination = normalizedNonEmpty(connection.metadata.destinationIP).map { "\($0):\(connection.metadata.destinationPort ?? "--")" } ?? "--"
        return "\(source) → \(destination)"
    }

    private static func icon(for domain: String, process: String?) -> String {
        let lowercasedDomain = domain.lowercased()
        let lowercasedProcess = process?.lowercased() ?? ""

        if lowercasedDomain.contains("google") {
            return "🛡"
        }
        if lowercasedDomain.contains("telegram") || lowercasedDomain.contains("tg") {
            return "✈️"
        }
        if lowercasedDomain.contains("apple") || lowercasedProcess.contains("cloud") {
            return "☁️"
        }
        if lowercasedProcess.contains("chrome") || lowercasedProcess.contains("safari") {
            return "🌐"
        }

        return "🌐"
    }

    private static func timestampText(from date: Date?) -> String {
        guard let date else {
            return Self.timeFormatter.string(from: Date())
        }

        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private enum NetworkControllerLoader {
    static func makeClient() -> MihomoControllerClient? {
        guard
            let configurationURL = FluxBarDefaultConfigurationLocator.locate(),
            let text = try? String(contentsOf: configurationURL, encoding: .utf8),
            let controllerAddress = scalarValue(for: "external-controller", in: text),
            controllerAddress.isEmpty == false,
            let configuration = try? MihomoControllerConfiguration(
                controllerAddress: controllerAddress,
                secret: scalarValue(for: "secret", in: text),
                preferLoopbackAccess: true
            )
        else {
            return nil
        }

        return MihomoControllerClient(configuration: configuration)
    }

    private static func scalarValue(for key: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.hasPrefix("#") == false && line.hasPrefix("\(key):")
            }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }
}

struct NetworkPageView: View {
    @State private var connections: [NetworkConnection] = []
    @State private var searchKeyword = ""
    @State private var selectedProtocol: NetworkProtocolFilter = .all
    @State private var isRefreshing = false
    @State private var statusText = "等待连接监控"
    @State private var routeStrategyMap = FluxBarRouteStrategyMap(ruleSetStrategies: [:], inlineStrategies: [:])

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                connectionsCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await reloadConnections()
        }
        .onReceive(NotificationCenter.default.publisher(for: fluxBarConfigurationDidRefreshNotification)) { _ in
            Task {
                await reloadConnections()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: fluxBarConnectionMonitorDidUpdate)) { _ in
            Task {
                await reloadConnections()
            }
        }
    }

    private var connectionsCard: some View {
        FluxCard(
            title: "网络连接",
            trailing: {
                HStack(spacing: 8) {
                    FluxChip(title: statusText, tone: .neutral)
                    FluxChip(title: "\(filteredConnections.count)", tone: .accent, monospace: true)
                }
            }
        ) {
            toolbar
            connectionsList
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)

                TextField("过滤域名、IP、策略或规则集", text: $searchKeyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FluxTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)

            Menu {
                ForEach(NetworkProtocolFilter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) {
                        selectedProtocol = filter
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedProtocol.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .black))
                }
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(FluxTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Button {
                Task {
                    await clearConnections()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.49, blue: 0.49),
                                Color(red: 0.95, green: 0.24, blue: 0.24)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .shadow(color: Color.red.opacity(0.24), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
        }
    }

    private var connectionsList: some View {
        LazyVStack(spacing: 8) {
            if filteredConnections.isEmpty {
                FluxListRow(
                    icon: "🔍",
                    title: emptyStateTitle,
                    subtitle: emptyStateSubtitle
                ) {
                    FluxChip(title: selectedProtocol.rawValue, tone: .warning)
                }
            } else {
                ForEach(filteredConnections) { item in
                    connectionRow(item)
                }
            }
        }
    }

    private var filteredConnections: [NetworkConnection] {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = connections

        if keyword.isEmpty == false {
            list = list.filter { item in
                "\(item.title) \(item.actualRoute) \(item.ruleSetName) \(item.strategyGroupName)".lowercased().contains(keyword)
            }
        }

        if let transport = selectedProtocol.transport {
            list = list.filter { $0.transport.contains(transport) }
        }

        return list
    }

    private func connectionRow(_ item: NetworkConnection) -> some View {
        FluxInteractiveRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(item.icon) \(item.title)")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(FluxTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)

                        FluxChip(title: item.ruleSetName, tone: item.ruleTone, monospace: false)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.time) · \(item.transport) · ↑ \(trafficString(item.uploadBytes)) · ↓ \(trafficString(item.downloadBytes))")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(2)

                        Spacer(minLength: 6)

                        Text(routeSummary(for: item))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(FluxTheme.textSecondary)
                }
            }
        }
    }

    private func routeSummary(for item: NetworkConnection) -> String {
        let left = item.strategyGroupName.isEmpty ? "直连" : item.strategyGroupName
        let right = item.actualRoute.isEmpty ? left : item.actualRoute
        if left == right {
            return left
        }
        return "\(left) → \(right)"
    }

    private func trafficString(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        }
        if value >= 1_024 {
            return String(format: "%.1f KB", value / 1_024)
        }
        return "\(bytes) B"
    }

    private func clearConnections() async {
        let kernelStatus = await KernelManager.shared.runningStatus()
        guard kernelStatus.isRunning else {
            statusText = "需先启动内核"
            return
        }

        guard let client = NetworkControllerLoader.makeClient() else {
            statusText = "Controller 未配置"
            return
        }

        do {
            try await client.closeAllConnections()
            await reloadConnections()
        } catch {
            statusText = "关闭失败"
        }
    }

    private func reloadConnections() async {
        guard isRefreshing == false else {
            return
        }

        await MainActor.run {
            isRefreshing = true
        }

        defer {
            Task { @MainActor in
                isRefreshing = false
            }
        }

        let configurationURL = FluxBarDefaultConfigurationLocator.locate()
        let strategyMap = FluxBarConfigurationSupport.routeStrategyMap(from: configurationURL)
        let kernelStatus = await KernelManager.shared.runningStatus()
        let monitorSnapshot = await FluxBarConnectionMonitor.shared.snapshot()

        let mappedConnections: [NetworkConnection]
        let nextStatusText: String

        if let client = NetworkControllerLoader.makeClient(),
           let snapshot = try? await client.fetchConnections() {
            mappedConnections = snapshot.connections
                .sorted { lhs, rhs in
                    let lhsDate = lhs.start ?? .distantPast
                    let rhsDate = rhs.start ?? .distantPast
                    return lhsDate > rhsDate
                }
                .map { NetworkConnection.make(from: $0, mapping: strategyMap) }
            nextStatusText = mappedConnections.isEmpty ? "暂无活动连接" : "连接监控运行中"
        } else if monitorSnapshot.records.isEmpty == false {
            mappedConnections = monitorSnapshot.records.map { NetworkConnection.make(from: $0.connection, mapping: strategyMap) }
            nextStatusText = monitorSnapshot.statusMessage
        } else if kernelStatus.isRunning == false {
            mappedConnections = []
            nextStatusText = "内核未运行"
        } else if NetworkControllerLoader.makeClient() == nil {
            mappedConnections = []
            nextStatusText = "Controller 未配置"
        } else {
            mappedConnections = []
            nextStatusText = "连接流暂时不可用"
        }

        await MainActor.run {
            routeStrategyMap = strategyMap
            connections = mappedConnections
            statusText = nextStatusText
        }
    }

    private var emptyStateTitle: String {
        if statusText == "内核未运行" {
            return "内核尚未运行"
        }

        if statusText == "Controller 未配置" || statusText == "连接流暂时不可用" {
            return "无法读取实时连接"
        }

        return "没有匹配连接"
    }

    private var emptyStateSubtitle: String {
        if statusText == "内核未运行" {
            return "网络页依赖 mihomo controller 的连接流，请先启动内核"
        }

        if statusText == "Controller 未配置" {
            return "当前配置未启用 controller，请先确认 external-controller 已写入配置"
        }

        if statusText == "连接流暂时不可用" {
            return "controller 暂时没有返回连接流，稍后会自动重试"
        }

        return "请开启系统代理或启用 TUN，让流量真正进入当前内核"
    }
}
