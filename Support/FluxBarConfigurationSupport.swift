import CryptoKit
import Foundation

let fluxBarConfigurationDidRefreshNotification = Notification.Name("FluxBarConfigurationDidRefresh")

struct FluxBarProviderNodeSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let region: String
    let protocolName: String
}

struct FluxBarProviderDefinitionSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL?
    let path: String
}

struct FluxBarRuleProviderDefinitionSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL?
    let path: String
    let behavior: String?
    let format: String?
}

struct FluxBarProviderMetadataSnapshot: Codable, Sendable {
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

struct FluxBarLatencyContext: Sendable {
    let configuration: MihomoControllerConfiguration
    let targetURL: String
}

struct FluxBarControllerContext: Sendable {
    let controllerAddress: String
    let secret: String?
    let configuration: MihomoControllerConfiguration
    let panelURL: URL?
    let isExternalUIMounted: Bool
}

struct FluxBarRouteStrategyMap: Sendable {
    let ruleSetStrategies: [String: String]
    let inlineStrategies: [String: String]
}

struct FluxBarResolvedRoutingRuleRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let payload: String
    let type: String
    let strategy: String
    let count: Int
    let updatedAt: String
    let countKey: String

    var bucket: String {
        let proxyName = strategy.uppercased()
        if proxyName == "DIRECT" || strategy == "直连" {
            return "direct"
        }
        if count >= 200 {
            return "hot"
        }
        return "proxy"
    }
}

enum FluxBarConfigurationSupport {
    static let subscriptionUserAgent = "ClashforWindows/0.20.39"

    static func configurationText(from configurationURL: URL) -> String? {
        try? String(contentsOf: configurationURL, encoding: .utf8)
    }

    static func configurationSignature(for configurationURL: URL?) -> String? {
        guard
            let configurationURL,
            let data = try? Data(contentsOf: configurationURL)
        else {
            return nil
        }

        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func providerDefinitions(from configurationURL: URL) -> [FluxBarProviderDefinitionSnapshot] {
        guard let content = configurationText(from: configurationURL) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines)
        var isInSection = false
        var currentName: String?
        var currentURL: URL?
        var currentPath: String?
        var providers: [FluxBarProviderDefinitionSnapshot] = []

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
                FluxBarProviderDefinitionSnapshot(
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

    static func ruleProviderDefinitions(from configurationURL: URL) -> [FluxBarRuleProviderDefinitionSnapshot] {
        guard let content = configurationText(from: configurationURL) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines)
        let aliases = ruleProviderAliases(in: lines)
        var isInSection = false
        var currentName: String?
        var currentURL: URL?
        var currentPath: String?
        var currentBehavior: String?
        var currentFormat: String?
        var definitions: [FluxBarRuleProviderDefinitionSnapshot] = []

        func resetCurrent() {
            currentName = nil
            currentURL = nil
            currentPath = nil
            currentBehavior = nil
            currentFormat = nil
        }

        func flushCurrent() {
            guard
                let currentName,
                let currentPath,
                currentName.isEmpty == false,
                currentPath.isEmpty == false
            else {
                resetCurrent()
                return
            }

            definitions.append(
                FluxBarRuleProviderDefinitionSnapshot(
                    id: currentName,
                    name: currentName,
                    url: currentURL,
                    path: currentPath,
                    behavior: currentBehavior,
                    format: currentFormat
                )
            )
            resetCurrent()
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
            } else if rawLine.hasPrefix("    behavior:") {
                let rawValue = String(rawLine.dropFirst(13)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentBehavior = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if rawLine.hasPrefix("    format:") {
                let rawValue = String(rawLine.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentFormat = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if rawLine.hasPrefix("    <<: *") {
                let rawAlias = String(rawLine.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                let alias = rawAlias.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let definitionAlias = aliases[alias] {
                    currentBehavior = currentBehavior ?? definitionAlias.behavior
                    currentFormat = currentFormat ?? definitionAlias.format
                }
            }
        }

        flushCurrent()
        return definitions
    }

    static func refreshProviders(from configurationURL: URL, providerID: String? = nil) async throws -> (total: Int, success: Int) {
        let definitions = providerDefinitions(from: configurationURL)
            .filter { providerID == nil || $0.id == providerID }
        guard definitions.isEmpty == false else {
            return (0, 0)
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
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            try writeProviderMetadata(from: httpResponse, for: destinationURL)
            successCount += 1
        }

        return (definitions.count, successCount)
    }

    static func refreshRuleProviders(from configurationURL: URL) async throws -> (total: Int, success: Int) {
        let definitions = ruleProviderDefinitions(from: configurationURL)
        guard definitions.isEmpty == false else {
            return (0, 0)
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
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            successCount += 1
        }

        return (definitions.count, successCount)
    }

    static func loadProviderMetadata(for cacheURL: URL) -> FluxBarProviderMetadataSnapshot? {
        let url = providerMetadataURL(for: cacheURL)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(FluxBarProviderMetadataSnapshot.self, from: data)
    }

    static func loadProviderNodesMap(from configurationURL: URL?) -> [String: [FluxBarProviderNodeSnapshot]] {
        guard let configurationURL else {
            return [:]
        }

        var result: [String: [FluxBarProviderNodeSnapshot]] = [:]
        for definition in providerDefinitions(from: configurationURL) {
            let cacheURL = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
            result[definition.id] = parseProviderNodes(in: cacheURL)
        }
        return result
    }

    static func loadProviderNodes(for providerID: String, from configurationURL: URL?) -> [FluxBarProviderNodeSnapshot] {
        guard
            let configurationURL,
            let definition = providerDefinitions(from: configurationURL).first(where: { $0.id == providerID })
        else {
            return []
        }

        return parseProviderNodes(in: resolveCacheURL(for: definition.path, relativeTo: configurationURL))
    }

    static func latencyContext(from configurationURL: URL?) -> FluxBarLatencyContext? {
        guard
            let configurationURL,
            let text = configurationText(from: configurationURL),
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

        return FluxBarLatencyContext(
            configuration: configuration,
            targetURL: latencyTargetURL(in: text) ?? "https://www.gstatic.com/generate_204"
        )
    }

    static func controllerContext(from configurationURL: URL?) -> FluxBarControllerContext? {
        guard
            let configurationURL,
            let text = configurationText(from: configurationURL),
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

        let uiName = scalarValue(for: "external-ui-name", in: text)
        let panelURL = RuntimeConfigurationInspector.inspect(configurationURL: configurationURL).controller.panelURL
        let mounted = externalUIIsMounted(configurationURL: configurationURL, externalUIName: uiName)

        return FluxBarControllerContext(
            controllerAddress: controllerAddress,
            secret: scalarValue(for: "secret", in: text),
            configuration: configuration,
            panelURL: mounted ? panelURL : nil,
            isExternalUIMounted: mounted
        )
    }

    static func routeStrategyMap(from configurationURL: URL?) -> FluxBarRouteStrategyMap {
        guard
            let configurationURL,
            let content = configurationText(from: configurationURL)
        else {
            return FluxBarRouteStrategyMap(ruleSetStrategies: [:], inlineStrategies: [:])
        }

        let lines = content.components(separatedBy: .newlines)
        var isInRules = false
        var ruleSetStrategies: [String: String] = [:]
        var inlineStrategies: [String: String] = [:]

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("rules:") {
                isInRules = true
                continue
            }

            if isInRules, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                break
            }

            guard isInRules, trimmed.hasPrefix("- ") else {
                continue
            }

            let body = String(trimmed.dropFirst(2))
            let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let type = parts.first, parts.count >= 2 else {
                continue
            }

            switch type.uppercased() {
            case "RULE-SET":
                if parts.count >= 3 {
                    ruleSetStrategies[parts[1]] = parts[2]
                }
            case "MATCH":
                if parts.count >= 2 {
                    inlineStrategies["MATCH"] = parts[1]
                }
            default:
                if parts.count >= 3 {
                    inlineStrategies["\(type.uppercased()):\(parts[1])"] = parts[2]
                }
            }
        }

        return FluxBarRouteStrategyMap(
            ruleSetStrategies: ruleSetStrategies,
            inlineStrategies: inlineStrategies
        )
    }

    static func externalUIIsMounted(configurationURL: URL?, externalUIName: String?) -> Bool {
        guard let configurationURL else {
            return false
        }

        let uiRoot = configurationURL.deletingLastPathComponent().appendingPathComponent("ui", isDirectory: true)
        let normalizedName = externalUIName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedURL = normalizedName == "zashboard"
            ? uiRoot.appendingPathComponent("zashboard", isDirectory: true)
            : uiRoot

        return FileManager.default.fileExists(atPath: expectedURL.path)
    }

    static func strategyGroupCount(from configurationURL: URL?) -> Int {
        guard
            let configurationURL,
            let content = configurationText(from: configurationURL)
        else {
            return 0
        }

        let lines = content.components(separatedBy: .newlines)
        var isInProxyGroups = false
        var count = 0

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("proxy-groups:") {
                isInProxyGroups = true
                continue
            }

            if isInProxyGroups, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                break
            }

            guard isInProxyGroups, trimmed.hasPrefix("- {") else {
                continue
            }

            count += 1
        }

        return count
    }

    static func resolveRoutingRules(from configurationURL: URL) -> [FluxBarResolvedRoutingRuleRecord] {
        guard let content = configurationText(from: configurationURL) else {
            return []
        }

        let providerPaths = Dictionary(
            uniqueKeysWithValues: ruleProviderDefinitions(from: configurationURL).map {
                ($0.id, resolveCacheURL(for: $0.path, relativeTo: configurationURL))
            }
        )
        let configUpdatedAt = relativeTimeString(for: configurationURL)
        let lines = content.components(separatedBy: .newlines)
        var isInRules = false
        var offlineRules: [(id: String, payload: String, type: String, strategy: String, updatedAt: String, countKey: String)] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("rules:") {
                isInRules = true
                continue
            }

            if isInRules, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                break
            }

            guard isInRules, trimmed.hasPrefix("- ") else {
                continue
            }

            let body = String(trimmed.dropFirst(2))
            let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let type = parts.first, parts.count >= 2 else {
                continue
            }

            let payload: String
            let strategy: String
            switch type.uppercased() {
            case "MATCH":
                payload = "MATCH"
                strategy = parts.count > 1 ? parts[1] : "--"
            default:
                payload = parts[1]
                strategy = parts.count > 2 ? parts[2] : "--"
            }

            let updatedAt = providerPaths[payload].map(relativeTimeString(for:)) ?? configUpdatedAt
            let countKey = type.uppercased() == "RULE-SET"
                ? "RULE-SET:\(payload)"
                : "INLINE:\(type.uppercased()):\(payload):\(strategy)"

            offlineRules.append(
                (
                    id: "\(type)-\(payload)-\(strategy)",
                    payload: payload,
                    type: type,
                    strategy: strategy,
                    updatedAt: updatedAt,
                    countKey: countKey
                )
            )
        }

        let counts = resolvedRuleCounts(from: configurationURL)

        return offlineRules.map { rule in
            let resolvedCount: Int
            if rule.type.uppercased() == "RULE-SET" {
                resolvedCount = counts[rule.countKey] ?? 0
            } else {
                resolvedCount = max(counts[rule.countKey] ?? 0, 1)
            }

            return FluxBarResolvedRoutingRuleRecord(
                id: rule.id,
                payload: rule.payload,
                type: rule.type,
                strategy: rule.strategy,
                count: resolvedCount,
                updatedAt: rule.updatedAt,
                countKey: rule.countKey
            )
        }
    }

    static func resolveCacheURL(for path: String, relativeTo configurationURL: URL) -> URL {
        let baseURL = configurationURL.deletingLastPathComponent()
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        return baseURL.appendingPathComponent(path)
    }

    private static func resolvedRuleCounts(from configurationURL: URL) -> [String: Int] {
        var counts: [String: Int] = [:]

        for definition in ruleProviderDefinitions(from: configurationURL) {
            let cacheURL = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
            counts["RULE-SET:\(definition.id)"] = localRuleCount(
                in: cacheURL,
                behavior: definition.behavior,
                format: definition.format
            )
        }

        return counts
    }

    private static func localRuleCount(in fileURL: URL, behavior: String?, format: String?) -> Int {
        guard let data = try? Data(contentsOf: fileURL), data.isEmpty == false else {
            return 0
        }

        let resolvedFormat = (format ?? fileURL.pathExtension).lowercased()
        if resolvedFormat == "mrs" {
            return convertedMrsRuleCount(
                sourceURL: fileURL,
                behavior: behavior ?? inferredBehavior(for: fileURL.lastPathComponent)
            )
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return 0
        }

        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                line.isEmpty == false &&
                line.hasPrefix("#") == false &&
                line.hasPrefix("payload:") == false &&
                line.hasPrefix("rules:") == false &&
                line.hasPrefix("type:") == false
            }
            .count
    }

    private static func convertedMrsRuleCount(sourceURL: URL, behavior: String?) -> Int {
        guard let mihomoURL = try? DefaultKernelBinaryLocator().binaryURL(for: .mihomo, preferredURL: nil) else {
            return 0
        }

        let behavior = (behavior?.isEmpty == false ? behavior : nil) ?? "domain"
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fluxbar-rule-count", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let outputURL = temporaryRoot.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = mihomoURL
        process.arguments = ["convert-ruleset", behavior, "mrs", sourceURL.path, outputURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }

        guard process.terminationStatus == 0,
              let content = try? String(contentsOf: outputURL, encoding: .utf8)
        else {
            return 0
        }

        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                line.isEmpty == false &&
                line.hasPrefix("#") == false &&
                line.hasPrefix("payload:") == false &&
                line.hasPrefix("rules:") == false &&
                line.hasPrefix("type:") == false
            }
            .count
    }

    private static func parseProviderNodes(in url: URL) -> [FluxBarProviderNodeSnapshot] {
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

    private static func parseYAMLNodes(from content: String) -> [FluxBarProviderNodeSnapshot]? {
        guard content.contains("\nproxies:") || content.hasPrefix("proxies:") else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        var isInProxies = false
        var nodes: [FluxBarProviderNodeSnapshot] = []
        var currentName: String?
        var currentType: String?

        func flushCurrent() {
            guard let activeName = currentName, activeName.isEmpty == false else {
                return
            }

            nodes.append(
                FluxBarProviderNodeSnapshot(
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
                    FluxBarProviderNodeSnapshot(
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

    private static func parseSubscriptionNodes(from rawContent: String) -> [FluxBarProviderNodeSnapshot]? {
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

    private static func parseSubscriptionNode(from line: String) -> FluxBarProviderNodeSnapshot? {
        guard let schemeRange = line.range(of: "://") else {
            return nil
        }

        let scheme = String(line[..<schemeRange.lowerBound]).lowercased()
        let name: String

        if scheme == "vmess", let vmessName = parseVmessNodeName(from: line) {
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

        return FluxBarProviderNodeSnapshot(
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
        if let url = URL(string: line), let host = url.host, host.isEmpty == false {
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

    private static func providerMetadataURL(for cacheURL: URL) -> URL {
        cacheURL.appendingPathExtension("meta.json")
    }

    private static func writeProviderMetadata(from response: HTTPURLResponse, for cacheURL: URL) throws {
        guard let metadata = parseProviderMetadata(from: response) else {
            return
        }

        let data = try JSONEncoder().encode(metadata)
        try data.write(to: providerMetadataURL(for: cacheURL), options: .atomic)
    }

    private static func parseProviderMetadata(from response: HTTPURLResponse) -> FluxBarProviderMetadataSnapshot? {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key).lowercased()] = String(describing: item.value)
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

        let metadata = FluxBarProviderMetadataSnapshot(
            upload: extract("upload"),
            download: extract("download"),
            total: extract("total"),
            expire: extract("expire")
        )

        return metadata.upload != nil || metadata.download != nil || metadata.total != nil || metadata.expire != nil ? metadata : nil
    }

    private struct RuleProviderAlias {
        let behavior: String?
        let format: String?
    }

    private static func ruleProviderAliases(in lines: [String]) -> [String: RuleProviderAlias] {
        var aliases: [String: RuleProviderAlias] = [:]

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                trimmed.hasPrefix("RuleSet_"),
                let aliasRange = trimmed.range(of: "&"),
                let closingBraceIndex = trimmed.lastIndex(of: "}")
            else {
                continue
            }

            let aliasPart = trimmed[aliasRange.upperBound...]
            let alias = aliasPart.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard alias.isEmpty == false else {
                continue
            }

            let bodyStart = trimmed.index(after: aliasRange.lowerBound)
            let body = String(trimmed[bodyStart...closingBraceIndex])
            aliases[alias] = RuleProviderAlias(
                behavior: inlineMapValue(for: "behavior", in: body),
                format: inlineMapValue(for: "format", in: body)
            )
        }

        return aliases
    }

    private static func inlineMapValue(for key: String, in text: String) -> String? {
        let pattern = #"\b\#(key):\s*([^,}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[valueRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func inferredBehavior(for fileName: String) -> String {
        if fileName.localizedCaseInsensitiveContains("_ip") {
            return "ipcidr"
        }
        if fileName.localizedCaseInsensitiveContains("classical") {
            return "classical"
        }
        return "domain"
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

    private static func shouldIncludeNode(named name: String, type: String?) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            return false
        }

        let normalizedType = (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excludedTypes: Set<String> = ["select", "url-test", "fallback", "load-balance", "relay", "direct", "reject"]
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

    static func relativeTimeString(for fileURL: URL) -> String {
        let fileManager = FileManager.default
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return "未更新"
        }

        return relativeTimeString(from: modifiedAt)
    }

    static func relativeTimeString(from date: Date) -> String {
        let interval = Int(Date().timeIntervalSince(date))
        if interval < 60 {
            return "刚刚更新"
        }
        if interval < 3_600 {
            return "\(max(interval / 60, 1)) 分钟前"
        }
        if interval < 86_400 {
            return "\(max(interval / 3_600, 1)) 小时前"
        }
        return "\(max(interval / 86_400, 1)) 天前"
    }
}
