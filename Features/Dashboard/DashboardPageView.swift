import AppKit
import SwiftUI

private enum DashboardMode: String, CaseIterable {
    case rules = "规则"
    case global = "全局"
    case direct = "直连"
}

private enum DashboardPreferences {
    static let selectedModeKey = "dashboard.selectedMode"

    static func persistedMode() -> DashboardMode {
        let rawValue = FluxBarPreferences.string(for: selectedModeKey, fallback: DashboardMode.rules.rawValue)
        return DashboardMode(rawValue: rawValue) ?? .rules
    }

    static func persistMode(_ mode: DashboardMode) {
        FluxBarPreferences.set(mode.rawValue, for: selectedModeKey)
    }
}

@MainActor
private enum DashboardSessionState {
    static var didAutoRefreshProviders = false
    static var didAutoMeasureProviders = false
}

private struct DashboardProvider: Identifiable {
    let id: String
    let name: String
    let icon: String
    let updated: String
    let usageSummary: String
    let expiresSummary: String
    let progress: CGFloat?
    let progressColor: Color
    let sourceURL: URL?
    let cacheURL: URL
    let nodes: [DashboardProviderNode]
}

private struct DashboardProviderMetadata: Codable {
    let upload: Int64?
    let download: Int64?
    let total: Int64?
    let expire: Int64?

    var used: Int64? {
        guard let upload, let download else {
            return nil
        }

        return upload + download
    }

    var remaining: Int64? {
        guard let total, let used else {
            return nil
        }

        return max(total - used, 0)
    }
}

private struct DashboardProviderNode: Identifiable, Hashable {
    let id: String
    let name: String
    let region: String
    let protocolName: String
}

private struct DashboardProviderDefinition: Identifiable {
    let id: String
    let name: String
    let url: URL?
    let path: String
}

private struct DashboardProviderRefreshResult {
    let totalCount: Int
    let successCount: Int
}

private struct DashboardRuleProviderDefinition: Identifiable {
    let id: String
    let name: String
    let url: URL?
    let path: String
}

private struct DashboardRuleProviderRefreshResult {
    let totalCount: Int
    let successCount: Int
}

private struct DashboardProviderLatencyContext {
    let controllerAddress: String
    let secret: String?
    let targetURL: String
}

private enum DashboardProviderLatencyLoader {
    static func context(from configurationURL: URL?) -> DashboardProviderLatencyContext? {
        guard
            let configurationURL,
            let text = try? String(contentsOf: configurationURL, encoding: .utf8),
            let controllerAddress = scalarValue(for: "external-controller", in: text),
            controllerAddress.isEmpty == false
        else {
            return nil
        }

        let secret = scalarValue(for: "secret", in: text)
        let targetURL = latencyTargetURL(in: text) ?? "https://www.gstatic.com/generate_204"

        return DashboardProviderLatencyContext(
            controllerAddress: controllerAddress,
            secret: secret,
            targetURL: targetURL
        )
    }

    static func measure(
        nodes: [DashboardProviderNode],
        context: DashboardProviderLatencyContext,
        timeoutMilliseconds: Int = 2_000
    ) async -> [String: Int] {
        guard
            let configuration = try? MihomoControllerConfiguration(
                controllerAddress: context.controllerAddress,
                secret: context.secret,
                preferLoopbackAccess: true
            )
        else {
            return [:]
        }

        let client = MihomoControllerClient(configuration: configuration)

        return await withTaskGroup(of: (String, Int?).self, returning: [String: Int].self) { group in
            for node in nodes {
                group.addTask {
                    do {
                        let delay = try await client.testProxyDelay(
                            named: node.name,
                            targetURL: context.targetURL,
                            timeoutMilliseconds: timeoutMilliseconds
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
    }

    private static func scalarValue(for key: String, in text: String) -> String? {
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

    private static func latencyTargetURL(in text: String) -> String? {
        let patterns = [
            #"(?im)\b(type:\s*(?:url-test|fallback)[^\n]*?\burl:\s*['"]?([^,'"\s}]+))"#,
            #"(?im)\b(UrlTest:[^\n]*?\burl:\s*['"]?([^,'"\s}]+))"#,
            #"(?im)\b(FallBack:[^\n]*?\burl:\s*['"]?([^,'"\s}]+))"#,
            #"(?im)\b(health-check:\s*\{[^\n}]*?\burl:\s*['"]?([^,'"\s}]+))"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)
            guard
                let match = expression.firstMatch(in: text, range: range),
                let valueRange = Range(match.range(at: 2), in: text)
            else {
                continue
            }

            let value = String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if value.isEmpty == false {
                return value
            }
        }

        return nil
    }
}

private enum DashboardProviderLoader {
    private static let subscriptionUserAgent = "ClashforWindows/0.20.39"

    static func load(from configurationURL: URL?) -> [DashboardProvider] {
        guard let configurationURL else {
            return []
        }

        let definitions = definitions(from: configurationURL)

        return definitions.map { definition in
            let resolvedCacheURL = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
            let cacheExists = FileManager.default.fileExists(atPath: resolvedCacheURL.path)
            let cacheDate = cacheExists ? modificationDate(for: resolvedCacheURL) : nil
            let nodes = cacheExists ? parseNodes(in: resolvedCacheURL) : []
            let metadata = loadMetadata(for: resolvedCacheURL)
            let updated: String
            let usageSummaryText: String
            let expiresSummaryText: String
            let progress: CGFloat?
            let progressColor: Color

            if cacheExists, nodes.isEmpty == false {
                updated = cacheDate.map(relativeTimeString(from:)) ?? "刚刚更新"
                usageSummaryText = usageSummary(from: metadata)
                expiresSummaryText = expiresSummary(from: metadata)
                progress = usageProgress(from: metadata) ?? 1
                progressColor = FluxTheme.accentTop
            } else {
                updated = "更新失败"
                usageSummaryText = "剩余 -- / --"
                expiresSummaryText = "到期未知"
                progress = nil
                progressColor = Color(red: 0.89, green: 0.66, blue: 0.24)
            }

            return DashboardProvider(
                id: definition.name,
                name: definition.name,
                icon: icon(for: definition.name, host: definition.url?.host),
                updated: updated,
                usageSummary: usageSummaryText,
                expiresSummary: expiresSummaryText,
                progress: progress,
                progressColor: progressColor,
                sourceURL: definition.url,
                cacheURL: resolvedCacheURL,
                nodes: nodes
            )
        }
    }

    static func refresh(from configurationURL: URL?, providerID: String? = nil) async throws -> DashboardProviderRefreshResult {
        guard let configurationURL else {
            return .init(totalCount: 0, successCount: 0)
        }

        let definitions = definitions(from: configurationURL)
            .filter { providerID == nil || $0.id == providerID }
        guard definitions.isEmpty == false else {
            return .init(totalCount: 0, successCount: 0)
        }

        var successCount = 0

        for definition in definitions {
            guard let remoteURL = definition.url else {
                continue
            }

            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 20
            request.setValue(subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/yaml, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("24", forHTTPHeaderField: "Profile-Update-Interval")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200 ... 299).contains(httpResponse.statusCode)
            else {
                continue
            }

            let destinationURL = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: destinationURL, options: .atomic)
            try writeMetadata(from: httpResponse, for: destinationURL)
            successCount += 1
        }

        return .init(totalCount: definitions.count, successCount: successCount)
    }

    private static func definitions(from configurationURL: URL) -> [DashboardProviderDefinition] {
        guard let content = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return []
        }

        return parseProviderDefinitions(from: content)
    }

    private static func parseProviderDefinitions(from content: String) -> [DashboardProviderDefinition] {
        let lines = content.components(separatedBy: .newlines)
        var isInSection = false
        var currentName: String?
        var currentURL: URL?
        var currentPath: String?
        var providers: [DashboardProviderDefinition] = []

        func flushCurrent() {
            guard
                let activeName = currentName,
                let activePath = currentPath,
                activeName.isEmpty == false,
                activePath.isEmpty == false
            else {
                return
            }

            providers.append(
                DashboardProviderDefinition(
                    id: activeName,
                    name: activeName,
                    url: currentURL,
                    path: activePath
                )
            )
            currentName = nil
            currentURL = nil
            currentPath = nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("proxy-providers:") {
                isInSection = true
                continue
            }

            if isInSection, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                flushCurrent()
                break
            }

            guard isInSection, trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else {
                continue
            }

            if rawLine.hasPrefix("  "), rawLine.hasPrefix("    ") == false, trimmed.hasSuffix(":") {
                flushCurrent()
                currentName = String(trimmed.dropLast())
                currentURL = nil
                currentPath = nil
                continue
            }

            guard currentName != nil else {
                continue
            }

            if rawLine.hasPrefix("    url:") {
                let rawValue = String(rawLine.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentURL = URL(string: cleaned)
            } else if rawLine.hasPrefix("    path:") {
                let rawValue = String(rawLine.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentPath = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        flushCurrent()

        var seen = Set<String>()
        return providers.filter { seen.insert($0.id).inserted }
    }

    private static func resolveCacheURL(for path: String, relativeTo configurationURL: URL) -> URL {
        let baseURL = configurationURL.deletingLastPathComponent()
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        return baseURL.appendingPathComponent(path)
    }

    private static func metadataURL(for cacheURL: URL) -> URL {
        cacheURL.appendingPathExtension("meta.json")
    }

    private static func loadMetadata(for cacheURL: URL) -> DashboardProviderMetadata? {
        let url = metadataURL(for: cacheURL)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(DashboardProviderMetadata.self, from: data)
    }

    private static func writeMetadata(from response: HTTPURLResponse, for cacheURL: URL) throws {
        guard let metadata = parseMetadata(from: response) else {
            return
        }

        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: cacheURL), options: .atomic)
    }

    private static func parseMetadata(from response: HTTPURLResponse) -> DashboardProviderMetadata? {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { partialResult, item in
            partialResult[String(describing: item.key).lowercased()] = String(describing: item.value)
        }

        guard let rawValue = headers["subscription-userinfo"] ?? headers["subscription-user-info"] else {
            return nil
        }

        func extract(_ key: String) -> Int64? {
            guard
                let match = rawValue.range(of: #"(?i)\#(key)=([0-9]+)"#, options: .regularExpression),
                let valueRange = rawValue[match].range(of: #"([0-9]+)"#, options: .regularExpression)
            else {
                return nil
            }

            return Int64(rawValue[valueRange])
        }

        let metadata = DashboardProviderMetadata(
            upload: extract("upload"),
            download: extract("download"),
            total: extract("total"),
            expire: extract("expire")
        )

        return metadata.upload != nil || metadata.download != nil || metadata.total != nil || metadata.expire != nil ? metadata : nil
    }

    private static func usageSummary(from metadata: DashboardProviderMetadata?) -> String {
        guard
            let metadata,
            let remaining = metadata.remaining,
            let total = metadata.total
        else {
            return "剩余 -- / --"
        }

        return "剩余 \(formatDataSize(remaining)) / \(formatDataSize(total))"
    }

    private static func expiresSummary(from metadata: DashboardProviderMetadata?) -> String {
        guard
            let metadata,
            let expire = metadata.expire,
            expire > 0
        else {
            return "到期未知"
        }

        let expireDate = Date(timeIntervalSince1970: TimeInterval(expire))
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfExpire = calendar.startOfDay(for: expireDate)
        let dayCount = max((calendar.dateComponents([.day], from: startOfToday, to: startOfExpire).day ?? 0), 0)

        return "\(dayCount) 天后过期 (\(providerDateFormatter.string(from: expireDate)))"
    }

    private static func usageProgress(from metadata: DashboardProviderMetadata?) -> CGFloat? {
        guard
            let metadata,
            let used = metadata.used,
            let total = metadata.total,
            total > 0
        else {
            return nil
        }

        return CGFloat(min(max(Double(used) / Double(total), 0), 1))
    }

    private static func formatDataSize(_ bytes: Int64) -> String {
        let gbValue = Double(bytes) / 1_073_741_824
        if gbValue >= 1024 {
            let tbValue = gbValue / 1024
            let rounded = (tbValue * 10).rounded() / 10
            if rounded.rounded(.towardZero) == rounded {
                return "\(Int(rounded)) TB"
            }

            return String(format: "%.1f TB", rounded)
        }

        let rounded = (gbValue * 10).rounded() / 10
        if rounded.rounded(.towardZero) == rounded {
            return "\(Int(rounded)) GB"
        }

        return String(format: "%.1f GB", rounded)
    }

    private static func parseNodes(in url: URL) -> [DashboardProviderNode] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        if let yamlNodes = parseYAMLNodes(from: content), yamlNodes.isEmpty == false {
            return yamlNodes
        }

        if let subscriptionNodes = parseSubscriptionNodes(from: content), subscriptionNodes.isEmpty == false {
            return subscriptionNodes
        }

        return []
    }

    private static func parseYAMLNodes(from content: String) -> [DashboardProviderNode]? {
        guard content.contains("\nproxies:") || content.hasPrefix("proxies:") else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        var isInProxies = false
        var nodes: [DashboardProviderNode] = []
        var currentName: String?
        var currentType: String?

        func flushCurrent() {
            guard let activeName = currentName, activeName.isEmpty == false else {
                return
            }

            nodes.append(
                DashboardProviderNode(
                    id: activeName,
                    name: activeName,
                    region: regionLabel(for: activeName),
                    protocolName: normalizedProtocolName(currentType)
                )
            )
            currentName = nil
            currentType = nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("proxies:") {
                isInProxies = true
                continue
            }

            if isInProxies, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                flushCurrent()
                break
            }

            guard isInProxies, trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else {
                continue
            }

            if trimmed.hasPrefix("- {"), let body = inlineMapBody(from: trimmed), let name = field("name", in: body) {
                flushCurrent()
                let type = field("type", in: body)
                guard shouldIncludeNode(named: name, type: type) else {
                    continue
                }
                nodes.append(
                    DashboardProviderNode(
                        id: name,
                        name: name,
                        region: regionLabel(for: name),
                        protocolName: normalizedProtocolName(type)
                    )
                )
                continue
            }

            if trimmed.hasPrefix("- name:") {
                flushCurrent()
                let rawValue = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentName = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentType = nil
                continue
            }

            if trimmed.hasPrefix("name:"), currentName == nil {
                let rawValue = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentName = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                continue
            }

            if trimmed.hasPrefix("type:") {
                let rawValue = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentType = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        flushCurrent()

        var seen = Set<String>()
        return nodes.filter { seen.insert($0.id).inserted }
    }

    private static func parseSubscriptionNodes(from rawContent: String) -> [DashboardProviderNode]? {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let plainText: String
        if trimmed.contains("://") {
            plainText = trimmed
        } else if let decoded = decodeBase64Text(trimmed), decoded.contains("://") {
            plainText = decoded
        } else {
            return nil
        }

        let nodes = plainText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .compactMap(parseSubscriptionNode)

        guard nodes.isEmpty == false else {
            return nil
        }

        var seen = Set<String>()
        return nodes.filter { seen.insert($0.id).inserted }
    }

    private static func parseSubscriptionNode(from line: String) -> DashboardProviderNode? {
        guard let schemeRange = line.range(of: "://") else {
            return nil
        }

        let scheme = String(line[..<schemeRange.lowerBound]).lowercased()
        let name: String

        if scheme == "vmess",
           let vmessName = parseVmessNodeName(from: line) {
            name = vmessName
        } else if let hashIndex = line.lastIndex(of: "#") {
            let fragment = String(line[line.index(after: hashIndex)...])
            let decodedFragment = fragment.removingPercentEncoding ?? fragment
            name = decodedFragment.isEmpty ? defaultNodeName(for: line, scheme: scheme) : decodedFragment
        } else {
            name = defaultNodeName(for: line, scheme: scheme)
        }

        guard shouldIncludeNode(named: name, type: scheme) else {
            return nil
        }

        return DashboardProviderNode(
            id: line,
            name: name,
            region: regionLabel(for: name),
            protocolName: normalizedProtocolName(scheme)
        )
    }

    private static func parseVmessNodeName(from line: String) -> String? {
        let encoded = String(line.dropFirst("vmess://".count))
        guard
            let decoded = decodeBase64Text(encoded),
            let data = decoded.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let ps = object["ps"] as? String, ps.isEmpty == false {
            return ps
        }

        if let add = object["add"] as? String, add.isEmpty == false {
            return add
        }

        return nil
    }

    private static func defaultNodeName(for line: String, scheme: String) -> String {
        if
            let url = URL(string: line),
            let host = url.host,
            host.isEmpty == false
        {
            return host
        }

        return scheme.uppercased()
    }

    private static func decodeBase64Text(_ value: String) -> String? {
        let normalized = normalizeBase64(value)
        guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func normalizeBase64(_ value: String) -> String {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        return normalized
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func hostLabel(from url: URL) -> String? {
        guard let host = url.host, host.isEmpty == false else {
            return nil
        }

        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func icon(for name: String, host: String?) -> String {
        let lowercasedName = name.lowercased()
        let lowercasedHost = host?.lowercased() ?? ""

        if lowercasedName.contains("poly") || lowercasedHost.contains("poly") {
            return "🛰"
        }
        if lowercasedName.contains("emo") || lowercasedHost.contains("emo") {
            return "⚡️"
        }
        if lowercasedName.contains("hk") || lowercasedHost.contains("hong") {
            return "🇭🇰"
        }

        return "📡"
    }

    private static func normalizedProtocolName(_ value: String?) -> String {
        guard let value, value.isEmpty == false else {
            return "节点"
        }

        return value.uppercased()
    }

    private static func regionLabel(for name: String) -> String {
        if name.localizedCaseInsensitiveContains("香港") || name.localizedCaseInsensitiveContains("HK") || name.localizedCaseInsensitiveContains("Hong") {
            return "香港"
        }
        if name.localizedCaseInsensitiveContains("日本") || name.localizedCaseInsensitiveContains("JP") || name.localizedCaseInsensitiveContains("Tokyo") || name.localizedCaseInsensitiveContains("Osaka") {
            return "日本"
        }
        if name.localizedCaseInsensitiveContains("美国") || name.localizedCaseInsensitiveContains("US") || name.localizedCaseInsensitiveContains("America") || name.localizedCaseInsensitiveContains("Los Angeles") {
            return "美国"
        }
        if name.localizedCaseInsensitiveContains("新加坡") || name.localizedCaseInsensitiveContains("SG") || name.localizedCaseInsensitiveContains("Singapore") || name.localizedCaseInsensitiveContains("狮城") {
            return "新加坡"
        }
        if name.localizedCaseInsensitiveContains("台湾") || name.localizedCaseInsensitiveContains("TW") || name.localizedCaseInsensitiveContains("Taiwan") {
            return "台湾"
        }
        return "其他"
    }

    private static func inlineMapBody(from trimmedLine: String) -> String? {
        guard let openingBrace = trimmedLine.firstIndex(of: "{"), let closingBrace = trimmedLine.lastIndex(of: "}") else {
            return nil
        }

        guard openingBrace < closingBrace else {
            return nil
        }

        return String(trimmedLine[trimmedLine.index(after: openingBrace)..<closingBrace])
    }

    private static func field(_ key: String, in body: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?i)(?:^|,)\\s*\(escapedKey):\\s*([^,}]+)"

        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
            let range = Range(match.range(at: 1), in: body)
        else {
            return nil
        }

        let value = body[range]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        return value.isEmpty ? nil : value
    }

    private static func shouldIncludeNode(named name: String, type: String?) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            return false
        }

        let normalizedType = (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excludedTypes: Set<String> = [
            "select", "url-test", "fallback", "load-balance", "relay", "direct", "reject"
        ]
        if excludedTypes.contains(normalizedType) {
            return false
        }

        let lowercasedName = trimmedName.lowercased()
        let excludedFragments = [
            "剩余流量", "下次重置", "套餐到期", "官网", "倍率说明", "官方推荐",
            "会员群", "自动选择", "故障转移", "国外媒体", "国内媒体",
            "youtube", "netflix", "disneyplus", "disney plus", "appletv",
            "emby", "tiktok", "电报消息", "哔哩哔哩", "ai工具", "google fcm"
        ]
        if excludedFragments.contains(where: { lowercasedName.contains($0.lowercased()) }) {
            return false
        }

        if lowercasedName.contains("http://") || lowercasedName.contains("https://") {
            return false
        }

        let excludedExactNames: Set<String> = ["polyun", "emo"]
        if excludedExactNames.contains(lowercasedName) {
            return false
        }

        return true
    }

    private static func relativeTimeString(from date: Date) -> String {
        let interval = Int(Date().timeIntervalSince(date))

        if interval < 60 {
            return "刚刚更新"
        }

        if interval < 3600 {
            return "\(max(interval / 60, 1)) 分钟前"
        }

        if interval < 86_400 {
            return "\(max(interval / 3600, 1)) 小时前"
        }

        return "\(max(interval / 86_400, 1)) 天前"
    }

    private static let providerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

private enum DashboardRuleProviderLoader {
    private static let subscriptionUserAgent = "ClashforWindows/0.20.39"

    static func refresh(from configurationURL: URL?) async throws -> DashboardRuleProviderRefreshResult {
        guard let configurationURL else {
            return .init(totalCount: 0, successCount: 0)
        }

        let definitions = definitions(from: configurationURL)
        guard definitions.isEmpty == false else {
            return .init(totalCount: 0, successCount: 0)
        }

        var successCount = 0

        for definition in definitions {
            guard let remoteURL = definition.url else {
                continue
            }

            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 20
            request.setValue(subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/yaml, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("24", forHTTPHeaderField: "Profile-Update-Interval")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200 ... 299).contains(httpResponse.statusCode)
            else {
                continue
            }

            let destinationURL = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: destinationURL, options: .atomic)
            successCount += 1
        }

        return .init(totalCount: definitions.count, successCount: successCount)
    }

    private static func definitions(from configurationURL: URL) -> [DashboardRuleProviderDefinition] {
        guard let content = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines)
        var isInSection = false
        var currentName: String?
        var currentURL: URL?
        var currentPath: String?
        var definitions: [DashboardRuleProviderDefinition] = []

        func flushCurrent() {
            guard
                let currentName,
                let currentPath,
                currentName.isEmpty == false,
                currentPath.isEmpty == false
            else {
                return
            }

            definitions.append(
                DashboardRuleProviderDefinition(
                    id: currentName,
                    name: currentName,
                    url: currentURL,
                    path: currentPath
                )
            )

            selfReset()
        }

        func selfReset() {
            currentName = nil
            currentURL = nil
            currentPath = nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("rule-providers:") {
                isInSection = true
                continue
            }

            if isInSection, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                flushCurrent()
                break
            }

            guard isInSection, trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else {
                continue
            }

            if rawLine.hasPrefix("  "), rawLine.hasPrefix("    ") == false, trimmed.hasSuffix(":") {
                flushCurrent()
                currentName = String(trimmed.dropLast())
                continue
            }

            guard currentName != nil else {
                continue
            }

            if rawLine.hasPrefix("    url:") {
                let rawValue = String(rawLine.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentURL = URL(string: rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            } else if rawLine.hasPrefix("    path:") {
                let rawValue = String(rawLine.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentPath = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        flushCurrent()

        var seen = Set<String>()
        return definitions.filter { seen.insert($0.id).inserted }
    }

    private static func resolveCacheURL(for path: String, relativeTo configurationURL: URL) -> URL {
        let baseURL = configurationURL.deletingLastPathComponent()
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        return baseURL.appendingPathComponent(path)
    }
}

@MainActor
private final class DashboardConfigMenuBridge: NSObject {
    static let shared = DashboardConfigMenuBridge()

    private var actions: [UUID: () -> Void] = [:]

    func reset() {
        actions.removeAll()
    }

    func item(title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let identifier = UUID()
        actions[identifier] = action

        let item = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = identifier
        item.isEnabled = enabled
        return item
    }

    @objc
    private func handleMenuItem(_ sender: NSMenuItem) {
        guard
            let identifier = sender.representedObject as? UUID,
            let action = actions[identifier]
        else {
            return
        }

        action()
    }
}

struct DashboardPageView: View {
    @ObservedObject var runtimeStore: FluxBarRuntimeStore
    @ObservedObject var summaryStore: FluxBarDashboardSummaryStore
    var onShowToast: (String) -> Void = { _ in }

    @State private var selectedMode: DashboardMode = DashboardPreferences.persistedMode()
    @State private var systemProxyEnabled = FluxBarPreferences.bool(for: "settings.systemProxyEnabled", fallback: false)
    @State private var isApplyingSystemProxy = false
    @State private var pendingSystemProxyTarget: Bool?
    @State private var providers: [DashboardProvider] = []
    @State private var isRefreshingProviders = false
    @State private var activeProviderID: String?
    @State private var isResolvingProviderNodes = false
    @State private var providerLatencyCache: [String: [String: Int]] = [:]
    @State private var latencyTestingProviderIDs: Set<String> = []

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    modeCard
                    summaryCard
                    providersCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            FluxSheet(
                isPresented: providerSheetBinding,
                title: activeProvider?.name ?? "订阅节点",
                subtitle: activeProvider.map { _ in "查看该订阅下的所有节点" }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("节点数：\(activeProvider?.nodes.count ?? 0)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FluxTheme.textSecondary)

                        Spacer(minLength: 8)

                        inlineActionButton(title: isTestingActiveProvider ? "测试中" : "延迟测试") {
                            Task {
                                await measureActiveProviderLatencies(manual: true)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.82), lineWidth: 1)
                    )

                    ScrollView(showsIndicators: false) {
                        providerSheetContent
                    }
                    .frame(maxHeight: 560)
                }
            }
        }
        .onChange(of: selectedMode) { _, newValue in
            DashboardPreferences.persistMode(newValue)
            onShowToast("已切换到 \(newValue.rawValue) 模式")
        }
        .onChange(of: systemProxyEnabled) { _, isEnabled in
            Task {
                await applySystemProxyChange(isEnabled)
            }
        }
        .onAppear {
            reloadProviders()
            loadPersistedProviderLatencies()
            Task {
                await summaryStore.refreshNow()
            }

        }
        .onReceive(NotificationCenter.default.publisher(for: fluxBarConfigurationDidRefreshNotification)) { _ in
            reloadProviders()
            loadPersistedProviderLatencies()
            Task {
                await summaryStore.refreshNow()
            }
        }
        .onChange(of: runtimeStore.kernelStatus.phase) { _, newPhase in
            guard
                newPhase == .running,
                providers.isEmpty == false,
                ProviderLatencyCacheStore.load(configurationURL: runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()) == nil
            else {
                return
            }

            Task {
                await premeasureAllProviderLatenciesIfPossible()
            }
        }
        .onChange(of: runtimeStore.kernelStatus.configurationURL) { _, _ in
            reloadProviders()
            Task {
                await summaryStore.refreshNow()
            }
        }
    }

    private var modeCard: some View {
        FluxCard(title: "网络模式") {
            GeometryReader { proxy in
                let panelWidth = max((proxy.size.width - 10) / 2, 0)

                HStack(alignment: .top, spacing: 10) {
                    FluxSegmentedControl(
                        options: DashboardMode.allCases.map { FluxSegmentedOption(value: $0, title: $0.rawValue) },
                        selection: $selectedMode,
                        appearance: .compact
                    )
                    .frame(width: panelWidth, height: 66)

                    systemProxyPanel
                        .frame(width: panelWidth)
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .frame(height: systemProxyRequiresKernelWarning ? 84 : 66)
        }
    }

    private var systemProxyPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("🌐")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.white.opacity(0.82), lineWidth: 1)
                    )

                Text("系统代理")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(FluxTheme.textPrimary)

                Spacer(minLength: 8)

                FluxToggle(isOn: $systemProxyEnabled, isEnabled: true, isLoading: isApplyingSystemProxy)
            }

            if systemProxyRequiresKernelWarning {
                Text("系统代理已开启，但内核未运行，流量不会被转发")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FluxTheme.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: systemProxyRequiresKernelWarning ? 84 : 66, alignment: .leading)
        .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }

    private var summaryCard: some View {
        FluxCard(title: "快速总览") {
            LazyVGrid(columns: gridColumns, spacing: 6) {
                summaryBlock(
                    title: "策略组",
                    value: "\(summaryStore.strategyGroupCount)",
                    subtitle: "已配置出口策略"
                )

                summaryBlock(
                    title: "活跃连接",
                    value: "\(summaryStore.activeConnectionCount)",
                    subtitle: "实时网络会话"
                )

                trafficBlock(
                    title: "上传",
                    value: summaryStore.uploadRateText,
                    subtitle: summaryStore.uploadTotalText,
                    valueColor: FluxTheme.accentTop
                )

                trafficBlock(
                    title: "下载",
                    value: summaryStore.downloadRateText,
                    subtitle: summaryStore.downloadTotalText,
                    valueColor: FluxTheme.good
                )
            }
        }
    }

    private var providersCard: some View {
        FluxCard(title: "订阅管理", trailing: {
            inlineActionButton(title: isRefreshingProviders ? "刷新中" : "刷新配置") {
                Task {
                    await refreshConfiguration()
                }
            }
        }) {
            VStack(spacing: 10) {
                configManagementCard

                if providers.isEmpty {
                    FluxListRow(
                        icon: "📭",
                        title: "没有可显示的订阅",
                        subtitle: "当前配置里未发现 proxy-providers"
                    ) {
                        FluxChip(title: "真实数据模式", tone: .warning)
                    }
                } else {
                    ForEach(providers) { provider in
                        Button {
                            openProvider(provider)
                        } label: {
                            providerRow(provider)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var configManagementCard: some View {
        HStack(spacing: 8) {
            Text("🗂")
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.82), lineWidth: 1)
                )

            Text("配置管理")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(FluxTheme.textPrimary)

            Spacer(minLength: 8)

            configManagementMenuButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        )
    }

    private var configManagementMenuButton: some View {
        Button {
            presentConfigManagementMenu()
        } label: {
            HStack(spacing: 5) {
                Text("管理")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.white.opacity(0.84), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.82), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
    }

    private func summaryBlock(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundStyle(FluxTheme.textPrimary)
            }

            Spacer(minLength: 8)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FluxTheme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        )
    }

    private func trafficBlock(
        title: String,
        value: String,
        subtitle: String,
        valueColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(valueColor)
            }

            Spacer(minLength: 8)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FluxTheme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        )
    }

    private func providerRow(_ provider: DashboardProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(provider.icon)
                    .font(.system(size: 17))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.82), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(FluxTheme.textPrimary)

                    Text(provider.updated)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FluxTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Text("节点数：\(provider.nodes.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FluxTheme.textPrimary)
            }

            if let progress = provider.progress {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.black.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(provider.progressColor)
                                .frame(width: max(proxy.size.width * progress, 10))
                        }
                }
                .frame(height: 6)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(provider.usageSummary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FluxTheme.textSecondary)

                Spacer(minLength: 8)

                Text(provider.expiresSummary)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FluxTheme.textPrimary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        )
    }

    private func inlineActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color(red: 0.16, green: 0.25, blue: 0.37))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.86),
                                    Color.white.opacity(0.56)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.80), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var configManagementSummary: String {
        if let currentURL = runtimeStore.kernelStatus.configurationURL {
            return currentURL.lastPathComponent
        }

        if let fallbackURL = FluxBarDefaultConfigurationLocator.locate() {
            return fallbackURL.lastPathComponent
        }

        return "当前 YAML 与 Configs"
    }

    private func reloadProviders(showToast: Bool = false) {
        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        providers = DashboardProviderLoader.load(from: configurationURL)
        loadPersistedProviderLatencies()

        guard showToast else {
            return
        }

        if providers.isEmpty {
            onShowToast("未发现可显示的订阅源")
        } else {
            onShowToast("已读取 \(providers.count) 个订阅源")
        }
    }

    private func refreshProvidersDirectly(showToast: Bool, measureLatenciesOnSuccess: Bool = false) async {
        guard isRefreshingProviders == false else {
            return
        }

        isRefreshingProviders = true
        defer { isRefreshingProviders = false }

        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()

        do {
            let result = try await DashboardProviderLoader.refresh(from: configurationURL)
            providers = DashboardProviderLoader.load(from: configurationURL)
            loadPersistedProviderLatencies()

            if measureLatenciesOnSuccess, result.successCount > 0 {
                await premeasureAllProviderLatenciesIfPossible()
                loadPersistedProviderLatencies()
            }

            if showToast {
                if result.totalCount == 0 {
                    onShowToast("当前配置没有可刷新的订阅源")
                } else if result.successCount == result.totalCount {
                    onShowToast("已直连刷新 \(result.successCount) 个订阅源")
                } else {
                    onShowToast("已刷新 \(result.successCount)/\(result.totalCount) 个订阅源")
                }
            }
        } catch {
            providers = DashboardProviderLoader.load(from: configurationURL)
            if showToast {
                onShowToast("直连刷新订阅失败")
            }
        }
    }

    private func refreshConfiguration() async {
        guard isRefreshingProviders == false else {
            return
        }

        isRefreshingProviders = true
        defer { isRefreshingProviders = false }

        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()

        do {
            let refreshResult = try await FluxBarConfigurationRefreshCoordinator.shared.refreshAll(configurationURL: configurationURL)

            providers = DashboardProviderLoader.load(from: configurationURL)

            if refreshResult.providerSuccess > 0 {
                await premeasureAllProviderLatenciesIfPossible()
            }

            if runtimeStore.kernelStatus.isRunning {
                _ = try? await FluxBarKernelLifecycleController.shared.startOrRestartSelectedKernel(forceRestart: true)
            }

            if systemProxyEnabled {
                _ = await SystemProxyManager.shared.applyProxyState(
                    enabled: true,
                    configurationURL: runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
                )
            }

            await runtimeStore.refreshNow()
            loadPersistedProviderLatencies()
            NotificationCenter.default.post(name: fluxBarConfigurationDidRefreshNotification, object: nil)

            let providerSummary = refreshResult.providerTotal == 0 ? "订阅 0" : "订阅 \(refreshResult.providerSuccess)/\(refreshResult.providerTotal)"
            let ruleSummary = refreshResult.ruleTotal == 0 ? "规则 0" : "规则 \(refreshResult.ruleSuccess)/\(refreshResult.ruleTotal)"
            onShowToast("已刷新配置：\(providerSummary) · \(ruleSummary)")
        } catch {
            providers = DashboardProviderLoader.load(from: configurationURL)
            loadPersistedProviderLatencies()
            await runtimeStore.refreshNow()
            onShowToast("刷新配置失败")
        }
    }

    private func openProvider(_ provider: DashboardProvider) {
        activeProviderID = provider.id

        Task {
            if provider.nodes.isEmpty {
                await refreshProviderNodesIfNeeded(for: provider.id)
            }
        }
    }

    private func openDirectory(_ builder: () throws -> URL) {
        do {
            let directoryURL = try builder()
            NSWorkspace.shared.open(directoryURL)
            onShowToast("已打开配置目录")
        } catch {
            onShowToast("打开目录失败")
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    private func applySystemProxyChange(_ enabled: Bool) async {
        pendingSystemProxyTarget = enabled

        guard isApplyingSystemProxy == false else {
            return
        }

        isApplyingSystemProxy = true
        var latestSummary = "系统代理状态更新中"
        var latestTarget = enabled

        while let target = pendingSystemProxyTarget {
            pendingSystemProxyTarget = nil
            latestTarget = target
            let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
            latestSummary = await SystemProxyManager.shared.applyProxyState(enabled: target, configurationURL: configurationURL)
            FluxBarPreferences.set(target, for: "settings.systemProxyEnabled")
        }

        isApplyingSystemProxy = false
        if latestTarget && runtimeStore.kernelStatus.isRunning == false {
            onShowToast("\(latestSummary)，但内核未运行，流量不会被转发")
        } else {
            onShowToast(latestSummary)
        }
    }

    private var systemProxyRequiresKernelWarning: Bool {
        systemProxyEnabled && runtimeStore.kernelStatus.isRunning == false && runtimeStore.isSwitchingKernelMode == false
    }

    private func presentConfigManagementMenu() {
        let bridge = DashboardConfigMenuBridge.shared
        bridge.reset()

        let menu = NSMenu(title: "配置管理")
        menu.autoenablesItems = false

        let currentConfigItem = NSMenuItem(title: "配置文件", action: nil, keyEquivalent: "")
        let currentConfigSubmenu = NSMenu(title: "配置文件")

        if let currentURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate() {
            currentConfigSubmenu.addItem(
                bridge.item(title: "编辑配置文件") {
                    NSWorkspace.shared.open(currentURL)
                    onShowToast("已用外部应用打开配置文件")
                }
            )

            currentConfigSubmenu.addItem(NSMenuItem.separator())

            currentConfigSubmenu.addItem(
                bridge.item(title: currentURL.lastPathComponent) {
                    revealInFinder(currentURL)
                    onShowToast("已定位配置文件")
                }
            )
        }

        if currentConfigSubmenu.items.isEmpty {
            currentConfigSubmenu.addItem(NSMenuItem(title: "暂无可用配置", action: nil, keyEquivalent: ""))
            currentConfigSubmenu.items.last?.isEnabled = false
        }

        currentConfigItem.submenu = currentConfigSubmenu
        menu.addItem(currentConfigItem)

        let directoryItem = bridge.item(title: "配置目录") {
            openDirectory { try FluxBarStorageDirectories.configsRoot() }
        }
        menu.addItem(directoryItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private var activeProvider: DashboardProvider? {
        providers.first(where: { $0.id == activeProviderID })
    }

    private var providerSheetBinding: Binding<Bool> {
        Binding(
            get: { activeProviderID != nil },
            set: { isPresented in
                if isPresented == false {
                    activeProviderID = nil
                }
            }
        )
    }

    private var providerSheetContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isResolvingProviderNodes {
                FluxListRow(
                    icon: "⟳",
                    title: "正在解析节点",
                    subtitle: "正在直连拉取该订阅的节点信息"
                )
            } else if displayedProviderNodes.isEmpty {
                FluxListRow(
                    icon: "📭",
                    title: "没有可显示节点",
                    subtitle: "当前还没有解析到该订阅的节点"
                )
            } else {
                ForEach(groupedProviderNodes, id: \.region) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.region)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FluxTheme.textSecondary)

                        VStack(spacing: 8) {
                            ForEach(group.nodes) { node in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(node.name)
                                            .font(.system(size: 14, weight: .heavy))
                                            .foregroundStyle(FluxTheme.textPrimary)

                                        Text(node.protocolName)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(FluxTheme.textSecondary)
                                    }

                                    Spacer(minLength: 8)

                                    FluxChip(
                                        title: providerLatencyText(for: node),
                                        tone: providerLatencyTone(for: node),
                                        monospace: true
                                    )
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(.white.opacity(0.80), lineWidth: 1)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func refreshProviderNodesIfNeeded(for providerID: String) async {
        guard isResolvingProviderNodes == false else {
            return
        }

        guard let provider = providers.first(where: { $0.id == providerID }), provider.nodes.isEmpty else {
            return
        }

        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        guard configurationURL != nil else {
            return
        }

        isResolvingProviderNodes = true
        defer { isResolvingProviderNodes = false }

        do {
            _ = try await DashboardProviderLoader.refresh(from: configurationURL, providerID: providerID)
            providers = DashboardProviderLoader.load(from: configurationURL)
        } catch {
            onShowToast("直连解析订阅节点失败")
        }
    }

    private func premeasureAllProviderLatenciesIfPossible() async {
        guard runtimeStore.kernelStatus.isRunning else {
            return
        }

        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        guard
            let context = DashboardProviderLatencyLoader.context(from: configurationURL),
            providers.isEmpty == false
        else {
            return
        }

        for provider in providers where provider.nodes.isEmpty == false {
            let latencies = await DashboardProviderLatencyLoader.measure(nodes: provider.nodes, context: context)
            ProviderLatencyCacheStore.replaceProviderLatencies(
                providerID: provider.id,
                nodes: provider.nodes.map {
                    FluxBarProviderNodeSnapshot(
                        id: $0.id,
                        name: $0.name,
                        region: $0.region,
                        protocolName: $0.protocolName
                    )
                },
                latenciesByNodeID: latencies,
                targetURL: context.targetURL,
                configurationURL: configurationURL
            )
        }
        loadPersistedProviderLatencies()
    }

    private func measureActiveProviderLatencies(manual: Bool) async {
        guard let activeProviderID else {
            return
        }

        if latencyTestingProviderIDs.contains(activeProviderID) {
            return
        }

        if runtimeStore.kernelStatus.isRunning == false {
            if manual {
                onShowToast("内核未运行，无法测速")
            }
            return
        }

        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        guard let context = DashboardProviderLatencyLoader.context(from: configurationURL) else {
            if manual {
                onShowToast("Controller 未就绪，无法测速")
            }
            return
        }

        latencyTestingProviderIDs.insert(activeProviderID)
        defer {
            latencyTestingProviderIDs.remove(activeProviderID)
        }

        if let provider = providers.first(where: { $0.id == activeProviderID }), provider.nodes.isEmpty {
            await refreshProviderNodesIfNeeded(for: activeProviderID)
        }

        guard let provider = providers.first(where: { $0.id == activeProviderID }), provider.nodes.isEmpty == false else {
            if manual {
                onShowToast("当前订阅没有可测速节点")
            }
            return
        }

        let latencies = await DashboardProviderLatencyLoader.measure(nodes: provider.nodes, context: context)
        ProviderLatencyCacheStore.replaceProviderLatencies(
            providerID: activeProviderID,
            nodes: provider.nodes.map {
                FluxBarProviderNodeSnapshot(
                    id: $0.id,
                    name: $0.name,
                    region: $0.region,
                    protocolName: $0.protocolName
                )
            },
            latenciesByNodeID: latencies,
            targetURL: context.targetURL,
            configurationURL: configurationURL
        )
        loadPersistedProviderLatencies()

        if manual {
            onShowToast(latencies.isEmpty ? "延迟测量失败" : "延迟测量已完成")
        }
    }

    private func loadPersistedProviderLatencies() {
        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        providerLatencyCache = ProviderLatencyCacheStore.providerLatencies(configurationURL: configurationURL)
    }

    private func providerLatencyText(for node: DashboardProviderNode) -> String {
        if let latency = activeProviderLatencies[node.id] {
            return "\(latency) ms"
        }

        return isTestingActiveProvider ? "测速中" : "-- ms"
    }

    private func providerLatencyTone(for node: DashboardProviderNode) -> FluxTone {
        guard let latency = activeProviderLatencies[node.id] else {
            return .neutral
        }

        if latency >= 220 {
            return .critical
        }

        if latency >= 120 {
            return .warning
        }

        return .positive
    }

    private var isTestingActiveProvider: Bool {
        guard let activeProviderID else {
            return false
        }

        return latencyTestingProviderIDs.contains(activeProviderID)
    }

    private var activeProviderLatencies: [String: Int] {
        guard let activeProviderID else {
            return [:]
        }

        return providerLatencyCache[activeProviderID] ?? [:]
    }

    private var displayedProviderNodes: [DashboardProviderNode] {
        activeProvider?.nodes ?? []
    }

    private var groupedProviderNodes: [(region: String, nodes: [DashboardProviderNode])] {
        let order = ["香港", "日本", "新加坡", "台湾", "美国", "其他"]
        let grouped = Dictionary(grouping: displayedProviderNodes, by: \.region)

        return grouped
            .map { key, value in (region: key, nodes: value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { lhs, rhs in
                let leftIndex = order.firstIndex(of: lhs.region) ?? order.count
                let rightIndex = order.firstIndex(of: rhs.region) ?? order.count
                if leftIndex == rightIndex {
                    return lhs.region < rhs.region
                }
                return leftIndex < rightIndex
            }
    }
}
