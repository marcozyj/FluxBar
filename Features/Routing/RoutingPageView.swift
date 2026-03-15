import Foundation
import SwiftUI

private enum RoutingFilter: String, CaseIterable {
    case all = "全部"
    case hot = "高命中"
    case proxy = "代理"
    case direct = "直连"
}

private struct RoutingRule: Identifiable {
    let id: String
    let name: String
    let type: String
    let strategy: String
    let count: Int
    let updatedAt: String
    let bucket: String

    var countTone: FluxTone {
        if count >= 200 {
            return .warning
        }
        if count >= 50 {
            return .accent
        }
        if bucket == "direct" {
            return .neutral
        }
        return .positive
    }
}

private struct RoutingOfflineRule {
    let id: String
    let payload: String
    let type: String
    let strategy: String
    let updatedAt: String
    let countKey: String

    func makeDisplay(count: Int) -> RoutingRule {
        let proxyName = strategy.uppercased()
        let bucket: String
        if proxyName == "DIRECT" || strategy == "直连" {
            bucket = "direct"
        } else if count >= 200 {
            bucket = "hot"
        } else {
            bucket = "proxy"
        }

        return RoutingRule(
            id: id,
            name: payload,
            type: type,
            strategy: strategy,
            count: count,
            updatedAt: updatedAt,
            bucket: bucket
        )
    }
}

private struct RoutingRuleProviderDefinition {
    let id: String
    let url: URL?
    let path: String
    let behavior: String?
    let format: String?
}

private struct RoutingRuleProviderRefreshResult {
    let totalCount: Int
    let successCount: Int
}

private enum RoutingConfigurationLoader {
    static func loadRules(from configurationURL: URL) -> [RoutingOfflineRule] {
        guard let content = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return []
        }

        let providerPaths = ruleProviderPaths(in: content, relativeTo: configurationURL)
        let configUpdatedAt = relativeTimeString(for: configurationURL)
        let lines = content.components(separatedBy: .newlines)
        var isInRules = false
        var rules: [RoutingOfflineRule] = []

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
            let parts = body.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }

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
            rules.append(
                RoutingOfflineRule(
                    id: "\(type)-\(payload)-\(strategy)",
                    payload: payload,
                    type: type,
                    strategy: strategy,
                    updatedAt: updatedAt,
                    countKey: countKey(type: type, payload: payload, strategy: strategy)
                )
            )
        }

        return rules
    }

    static func resolvedRuleCounts(from configurationURL: URL) -> [String: Int] {
        resolvedRuleCountsFromLocalProviders(configurationURL: configurationURL)
    }

    private static func ruleProviderPaths(in content: String, relativeTo configurationURL: URL) -> [String: URL] {
        let definitions = definitions(in: content)
        var mapping: [String: URL] = [:]

        for definition in definitions {
            mapping[definition.id] = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
        }

        return mapping
    }

    private static func definitions(from configurationURL: URL) -> [RoutingRuleProviderDefinition] {
        guard let content = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return []
        }

        return definitions(in: content)
    }

    private static func definitions(in content: String) -> [RoutingRuleProviderDefinition] {
        let lines = content.components(separatedBy: .newlines)
        let aliases = ruleProviderAliases(in: lines)
        var isInSection = false
        var currentName: String?
        var currentURL: URL?
        var currentPath: String?
        var currentBehavior: String?
        var currentFormat: String?
        var definitions: [RoutingRuleProviderDefinition] = []

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
                RoutingRuleProviderDefinition(
                    id: currentName,
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

    private static func resolveCacheURL(for path: String, relativeTo configurationURL: URL) -> URL {
        let baseURL = configurationURL.deletingLastPathComponent()
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        return baseURL.appendingPathComponent(path)
    }

    private static func relativeTimeString(for fileURL: URL) -> String {
        let fileManager = FileManager.default
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return "未更新"
        }

        let interval = Int(Date().timeIntervalSince(modifiedAt))
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

    private static func resolvedRuleCountsFromLocalProviders(configurationURL: URL) -> [String: Int] {
        let definitions = definitions(from: configurationURL)
        var counts: [String: Int] = [:]

        for definition in definitions {
            let cacheURL = resolveCacheURL(for: definition.path, relativeTo: configurationURL)
            counts["RULE-SET:\(definition.id)"] = localRuleCount(
                in: cacheURL,
                behavior: definition.behavior,
                format: definition.format
            )
        }

        return counts
    }

    private static func localRuleCount(
        in fileURL: URL,
        behavior: String?,
        format: String?
    ) -> Int {
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

        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return 0
        }

        let outputURL = temporaryRoot.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = mihomoURL
        process.arguments = [
            "convert-ruleset",
            behavior,
            "mrs",
            sourceURL.path,
            outputURL.path
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }

        guard process.terminationStatus == 0 else {
            return 0
        }

        guard let content = try? String(contentsOf: outputURL, encoding: .utf8) else {
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

    private static func countKey(type: String, payload: String, strategy: String) -> String {
        if type.uppercased() == "RULE-SET" {
            return "RULE-SET:\(payload)"
        }

        return "INLINE:\(type.uppercased()):\(payload):\(strategy)"
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
            let behavior = inlineMapValue(for: "behavior", in: body)
            let format = inlineMapValue(for: "format", in: body)
            aliases[alias] = RuleProviderAlias(behavior: behavior, format: format)
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
}

struct RoutingPageView: View {
    @State private var selectedFilter: RoutingFilter = .all
    @State private var rules: [RoutingRule]
    @State private var isLoading = false

    init() {
        let configurationURL = FluxBarDefaultConfigurationLocator.locate()
        let cachedRules = RoutingRulesCacheStore.load(configurationURL: configurationURL)?.rules ?? []
        _rules = State(initialValue: cachedRules.map(Self.displayRule(from:)))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                overviewCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if rules.isEmpty {
                await reloadRules()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: fluxBarConfigurationDidRefreshNotification)) { _ in
            Task {
                await reloadRules()
            }
        }
    }

    private var overviewCard: some View {
        FluxCard(
            title: "规则总览",
            trailing: {
                FluxChip(title: "规则 \(rules.count)", tone: .accent, monospace: true)
            }
        ) {
            filterBar
            rulesList
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoutingFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(selectedFilter == filter ? .white : FluxTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(filterBackground(for: filter))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var rulesList: some View {
        VStack(spacing: 8) {
            if filteredRules.isEmpty {
                FluxListRow(icon: "📭", title: "暂无规则", subtitle: "当前配置还没有可显示的规则") {
                    FluxChip(title: isLoading ? "解析中" : "未解析", tone: .warning)
                }
            } else {
                ForEach(filteredRules) { rule in
                    ruleRow(rule)
                }
            }
        }
    }

    private var filteredRules: [RoutingRule] {
        switch selectedFilter {
        case .all:
            return rules
        case .hot:
            return rules.filter { $0.count >= 50 }
        case .proxy:
            return rules.filter { $0.bucket == "proxy" || $0.bucket == "hot" }
        case .direct:
            return rules.filter { $0.strategy == "直连" || $0.strategy.uppercased() == "DIRECT" || $0.bucket == "direct" }
        }
    }

    private func filterBackground(for filter: RoutingFilter) -> some View {
        Group {
            if selectedFilter == filter {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FluxTheme.accentFill)
                    .shadow(color: FluxTheme.accentTop.opacity(0.20), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.64))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.82), lineWidth: 1)
                    )
            }
        }
    }

    private func ruleRow(_ rule: RoutingRule) -> some View {
        FluxInteractiveRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(rule.name)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(FluxTheme.textPrimary)

                        Spacer(minLength: 8)

                        FluxChip(title: "\(rule.count)", tone: rule.countTone, monospace: true)
                    }

                    HStack(spacing: 10) {
                        Text("\(rule.type) · \(rule.strategy)")
                        Spacer(minLength: 8)
                        Text(rule.updatedAt)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FluxTheme.textSecondary)
                }
            }
        }
    }

    private func reloadRules() async {
        guard isLoading == false else {
            return
        }

        let configurationURL = FluxBarDefaultConfigurationLocator.locate()
        if let cachedRules = RoutingRulesCacheStore.load(configurationURL: configurationURL)?.rules {
            await MainActor.run {
                rules = cachedRules.map(Self.displayRule(from:))
            }
        }

        guard let configurationURL else {
            await MainActor.run {
                rules = []
                isLoading = false
            }
            return
        }

        await MainActor.run {
            isLoading = true
        }

        defer {
            Task { @MainActor in
                isLoading = false
            }
        }

        let mappedRules = RoutingRulesCacheStore.refresh(configurationURL: configurationURL)?.rules.map(Self.displayRule(from:)) ?? []

        await MainActor.run {
            rules = mappedRules
        }
    }

    private static func displayRule(from record: FluxBarResolvedRoutingRuleRecord) -> RoutingRule {
        RoutingRule(
            id: record.id,
            name: record.payload,
            type: record.type,
            strategy: record.strategy,
            count: record.count,
            updatedAt: record.updatedAt,
            bucket: record.bucket
        )
    }
}
