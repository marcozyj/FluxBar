import Foundation
import SwiftUI

private enum StrategyPagePreferences {
    static let showHiddenGroupsKey = "strategy.showHiddenGroups"
}

private enum StrategyGroupKind: String {
    case select = "select"
    case urlTest = "url-test"
    case fallback = "fallback"
    case unknown

    var title: String {
        switch self {
        case .select:
            return "手动选择"
        case .urlTest:
            return "自动测速"
        case .fallback:
            return "故障转移"
        case .unknown:
            return "未知"
        }
    }
}

private enum StrategyOptionBucket: String, CaseIterable, Hashable {
    case recommended = "推荐入口"
    case auto = "自动测速"
    case fallback = "故障转移"
    case region = "地区节点"
    case other = "其他"

    static let displayOrder: [StrategyOptionBucket] = [.recommended, .auto, .fallback, .region, .other]
}

private struct StrategyOption: Identifiable, Hashable {
    let id: String
    let rawName: String
    let title: String
    let icon: String
    let bucket: StrategyOptionBucket
    let regionLabel: String?
    let modeLabel: String
    let subtitle: String
    let baseLatency: Int

    func latency(for revision: Int, salt: Int) -> Int {
        let shifts = [-12, -5, 0, 8, 14, -7]
        let shift = shifts[(revision + salt) % shifts.count]
        return max(18, baseLatency + shift)
    }

    func tone(for revision: Int, salt: Int) -> FluxTone {
        let value = latency(for: revision, salt: salt)
        if value >= 180 {
            return .warning
        }

        if value >= 120 {
            return .accent
        }

        return .positive
    }
}

private struct StrategyGroup: Identifiable {
    let id: String
    let rawName: String
    let name: String
    let icon: String
    let kind: StrategyGroupKind
    let sourceAlias: String?
    let filterAlias: String?
    let options: [StrategyOption]
    var currentOptionID: String

    var bucketOrder: [StrategyOptionBucket] {
        StrategyOptionBucket.displayOrder.filter { bucket in
            options.contains(where: { $0.bucket == bucket })
        }
    }

    func currentOption() -> StrategyOption? {
        options.first(where: { $0.id == currentOptionID })
    }

    func options(in bucket: StrategyOptionBucket) -> [StrategyOption] {
        options.filter { $0.bucket == bucket }
    }

    func latency(for revision: Int) -> Int {
        guard let option = currentOption() else {
            return 0
        }

        return option.latency(for: revision, salt: stableSalt)
    }

    func tone(for revision: Int) -> FluxTone {
        guard let option = currentOption() else {
            return .neutral
        }

        return option.tone(for: revision, salt: stableSalt)
    }

    private var stableSalt: Int {
        id.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        } % 5
    }
}

private enum StrategyConfigurationLoader {
    static func loadGroups(showHiddenGroups: Bool = false) -> [StrategyGroup] {
        guard
            let configurationURL = FluxBarDefaultConfigurationLocator.locate(),
            let content = try? String(contentsOf: configurationURL, encoding: .utf8)
        else {
            return fallbackGroups
        }

        let anchorArrays = parseAnchorArrays(from: content)
        let groups = parseFunctionalGroups(
            from: content,
            anchorArrays: anchorArrays,
            showHiddenGroups: showHiddenGroups
        )
        return groups.isEmpty ? fallbackGroups : groups
    }

    private static func parseAnchorArrays(from content: String) -> [String: [String]] {
        let lines = content.components(separatedBy: .newlines)
        var arrays: [String: [String]] = [:]
        var currentKey: String?
        var buffer: [String] = []

        for rawLine in lines {
            if let activeKey = currentKey {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }

                if trimmed == "]" {
                    arrays[activeKey] = parseArrayItems(from: buffer.joined(separator: " "))
                    buffer.removeAll()
                    currentKey = nil
                    continue
                }

                if trimmed.hasSuffix("]") {
                    let line = String(trimmed.dropLast())
                    if line.isEmpty == false {
                        buffer.append(line)
                    }

                    arrays[activeKey] = parseArrayItems(from: buffer.joined(separator: " "))
                    buffer.removeAll()
                    currentKey = nil
                    continue
                }

                buffer.append(trimmed)
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else {
                continue
            }

            guard rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false else {
                continue
            }

            guard rawLine.contains(": &"), let colonIndex = rawLine.firstIndex(of: ":") else {
                continue
            }

            let key = String(rawLine[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false else {
                continue
            }

            guard let openingBracket = rawLine.firstIndex(of: "[") else {
                continue
            }

            let suffix = rawLine[rawLine.index(after: openingBracket)...]
            if let closingBracket = suffix.firstIndex(of: "]") {
                let inlineItems = String(suffix[..<closingBracket])
                arrays[key] = parseArrayItems(from: inlineItems)
            } else {
                currentKey = key
                let inlinePrefix = String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
                if inlinePrefix.isEmpty == false {
                    buffer.append(inlinePrefix)
                }
            }
        }

        return arrays
    }

    private static func parseFunctionalGroups(
        from content: String,
        anchorArrays: [String: [String]],
        showHiddenGroups: Bool
    ) -> [StrategyGroup] {
        let lines = content.components(separatedBy: .newlines)
        var isInProxyGroups = false
        var groups: [StrategyGroup] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("proxy-groups:") {
                isInProxyGroups = true
                continue
            }

            if isInProxyGroups, rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false, trimmed.isEmpty == false {
                break
            }

            guard isInProxyGroups, trimmed.hasPrefix("- {"), let body = inlineMapBody(from: trimmed) else {
                continue
            }

            guard let rawName = field("name", in: body) else {
                continue
            }

            let alias = field("<<", in: body)?.replacingOccurrences(of: "*", with: "")
            let explicitType = field("type", in: body)?.lowercased()
            let kind = kindFor(alias: alias, explicitType: explicitType)
            let isHidden = field("hidden", in: body)?.lowercased() == "true"
            guard
                shouldDisplayGroup(
                    named: rawName,
                    isHidden: isHidden,
                    kind: kind,
                    showHiddenGroups: showHiddenGroups
                )
            else {
                continue
            }

            let sourceAlias = field("proxies", in: body)?.replacingOccurrences(of: "*", with: "")
            let filterAlias = field("filter", in: body)?.replacingOccurrences(of: "*", with: "")
            let rawOptions = optionsFor(sourceAlias: sourceAlias, inlineValue: field("proxies", in: body), anchorArrays: anchorArrays)
            let options = rawOptions.map(makeOption(from:))

            if options.isEmpty, showHiddenGroups == false {
                continue
            }

            let (icon, name) = splitLeadingSymbol(rawName)
            let currentOptionID = defaultCurrentOptionID(for: name, options: options)

            groups.append(
                StrategyGroup(
                    id: rawName,
                    rawName: rawName,
                    name: name,
                    icon: icon,
                    kind: kind,
                    sourceAlias: sourceAlias,
                    filterAlias: filterAlias,
                    options: options,
                    currentOptionID: currentOptionID
                )
            )
        }

        return groups
    }

    private static func shouldDisplayGroup(
        named rawName: String,
        isHidden: Bool,
        kind: StrategyGroupKind,
        showHiddenGroups: Bool
    ) -> Bool {
        if showHiddenGroups {
            if isHidden {
                return true
            }

            if kind == .urlTest || kind == .fallback {
                return true
            }

            if rawName.contains("自动") || rawName.contains("故转") {
                return true
            }
        }

        return rawName.contains("默认代理")
            || rawName.contains("AIGC")
            || rawName.contains("Steam")
            || rawName.contains("OneDrive")
            || rawName.contains("Microsoft")
            || rawName.contains("GitHub")
            || rawName == "✖️ X"
            || rawName.contains("Sony")
            || rawName.contains("Telegram")
            || rawName.contains("Google")
            || rawName.contains("YouTube")
            || rawName.contains("漏网之鱼")
    }

    private static func kindFor(alias: String?, explicitType: String?) -> StrategyGroupKind {
        if let explicitType {
            return StrategyGroupKind(rawValue: explicitType) ?? .unknown
        }

        switch alias {
        case "UrlTest":
            return .urlTest
        case "FallBack":
            return .fallback
        case "Select":
            return .select
        default:
            return .unknown
        }
    }

    private static func optionsFor(sourceAlias: String?, inlineValue: String?, anchorArrays: [String: [String]]) -> [String] {
        if let sourceAlias, let values = anchorArrays[sourceAlias] {
            return values
        }

        guard let inlineValue else {
            return []
        }

        if inlineValue.hasPrefix("[") {
            return parseArrayItems(from: inlineValue.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        }

        return []
    }

    private static func makeOption(from rawName: String) -> StrategyOption {
        let (icon, title) = splitLeadingSymbol(rawName)
        let bucket = bucketForOption(named: rawName)
        let regionLabel = regionLabel(from: rawName)
        let modeLabel = modeLabel(for: rawName, bucket: bucket)
        let subtitle = subtitle(for: rawName, bucket: bucket, regionLabel: regionLabel)
        let baseLatency = baseLatency(for: rawName, bucket: bucket, regionLabel: regionLabel)

        return StrategyOption(
            id: rawName,
            rawName: rawName,
            title: title,
            icon: icon,
            bucket: bucket,
            regionLabel: regionLabel,
            modeLabel: modeLabel,
            subtitle: subtitle,
            baseLatency: baseLatency
        )
    }

    private static func bucketForOption(named rawName: String) -> StrategyOptionBucket {
        if rawName == "直连" || rawName.contains("自动选择") || rawName.contains("全部节点") {
            return .recommended
        }

        if rawName.contains("故转") {
            return .fallback
        }

        if rawName.contains("自动") {
            return .auto
        }

        if rawName.contains("节点") {
            return .region
        }

        return .other
    }

    private static func regionLabel(from rawName: String) -> String? {
        if rawName.contains("美国") {
            return "美国"
        }
        if rawName.contains("日本") {
            return "日本"
        }
        if rawName.contains("狮城") || rawName.contains("新加坡") {
            return "狮城"
        }
        if rawName.contains("台湾") {
            return "台湾"
        }
        if rawName.contains("香港") {
            return "香港"
        }
        return nil
    }

    private static func modeLabel(for rawName: String, bucket: StrategyOptionBucket) -> String {
        if rawName == "直连" {
            return "Direct"
        }

        switch bucket {
        case .recommended:
            return rawName.contains("全部节点") ? "Manual Pool" : "Selector"
        case .auto:
            return "Url-Test"
        case .fallback:
            return "Fallback"
        case .region:
            return "Region Pool"
        case .other:
            return "Selector"
        }
    }

    private static func subtitle(for rawName: String, bucket: StrategyOptionBucket, regionLabel: String?) -> String {
        if rawName == "直连" {
            return "不经过代理，直接连接"
        }

        if rawName.contains("自动选择") {
            return "总入口组，由 mihomo 在上层策略中继续分派"
        }

        if rawName.contains("全部节点") {
            return "手动入口，汇总所有订阅节点"
        }

        switch bucket {
        case .auto:
            return "\(regionLabel ?? "当前地区")测速组，按延迟自动挑选最快出口"
        case .fallback:
            return "\(regionLabel ?? "当前地区")故障转移组，节点失效时自动切换"
        case .region:
            return "\(regionLabel ?? "当前地区")手动节点池，作为地区专用出口入口"
        case .recommended:
            return "推荐入口，供上层策略直接选择"
        case .other:
            return "策略入口"
        }
    }

    private static func baseLatency(for rawName: String, bucket: StrategyOptionBucket, regionLabel: String?) -> Int {
        if rawName == "直连" {
            return 22
        }

        let regionBase: Int
        switch regionLabel {
        case "香港":
            regionBase = 54
        case "日本":
            regionBase = 86
        case "狮城":
            regionBase = 104
        case "台湾":
            regionBase = 96
        case "美国":
            regionBase = 174
        default:
            regionBase = 72
        }

        switch bucket {
        case .recommended:
            if rawName.contains("全部节点") {
                return 74
            }

            if rawName.contains("自动选择") {
                return 62
            }

            return regionBase
        case .auto:
            return regionBase
        case .fallback:
            return regionBase + 18
        case .region:
            return regionBase + 6
        case .other:
            return regionBase + 10
        }
    }

    private static func defaultCurrentOptionID(for groupName: String, options: [StrategyOption]) -> String {
        if ["Steam", "OneDrive", "Microsoft"].contains(groupName), let direct = options.first(where: { $0.rawName == "直连" }) {
            return direct.id
        }

        if let autoSelect = options.first(where: { $0.rawName.contains("自动选择") }) {
            return autoSelect.id
        }

        if let first = options.first {
            return first.id
        }

        return groupName
    }

    private static func splitLeadingSymbol(_ rawName: String) -> (String, String) {
        let parts = rawName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }

        return ("🌐", rawName)
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
        let pattern = "(?:^|,)\\s*\(escapedKey):\\s*([^,}]+)"

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

    private static func parseArrayItems(from content: String) -> [String] {
        content
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { $0.isEmpty == false }
    }

    private static var fallbackGroups: [StrategyGroup] {
        let definitions: [(String, [String])] = [
            ("🚀 默认代理", ["♻️ 自动选择", "🌐 全部节点", "直连", "♻️ 美国自动", "♻️ 日本自动", "♻️ 狮城自动", "🔯 美国故转", "🔯 日本故转", "🇺🇸 美国节点", "🇯🇵 日本节点", "🇸🇬 狮城节点", "🇭🇰 香港节点"]),
            ("🤖 AIGC", ["🔯 美国故转", "🔯 日本故转", "🔯 狮城故转"]),
            ("🎮 Steam", ["直连", "♻️ 自动选择", "🌐 全部节点", "🇺🇸 美国节点", "🇯🇵 日本节点"]),
            ("🍀 Google", ["🔯 美国故转", "🔯 日本故转", "🔯 狮城故转"]),
            ("✈️ Telegram", ["♻️ 自动选择", "🌐 全部节点", "🇭🇰 香港节点", "🇯🇵 日本节点", "🇺🇸 美国节点"]),
            ("👨🏿‍💻 GitHub", ["♻️ 自动选择", "🌐 全部节点", "🇯🇵 日本节点", "🇭🇰 香港节点", "🇺🇸 美国节点"])
        ]

        return definitions.map { rawName, optionNames in
            let (icon, name) = splitLeadingSymbol(rawName)
            let options = optionNames.map(makeOption(from:))
            return StrategyGroup(
                id: rawName,
                rawName: rawName,
                name: name,
                icon: icon,
                kind: .select,
                sourceAlias: nil,
                filterAlias: nil,
                options: options,
                currentOptionID: defaultCurrentOptionID(for: name, options: options)
            )
        }
    }
}

private struct StrategyControllerContext {
    let configuration: MihomoControllerConfiguration
    let targetURL: String
}

private enum StrategyControllerLoader {
    static func context() -> StrategyControllerContext? {
        guard
            let configurationURL = FluxBarDefaultConfigurationLocator.locate(),
            let content = try? String(contentsOf: configurationURL, encoding: .utf8),
            let controllerAddress = scalarValue(for: "external-controller", in: content),
            controllerAddress.isEmpty == false,
            let configuration = try? MihomoControllerConfiguration(
                controllerAddress: controllerAddress,
                secret: scalarValue(for: "secret", in: content),
                preferLoopbackAccess: true
            )
        else {
            return nil
        }

        return StrategyControllerContext(
            configuration: configuration,
            targetURL: latencyTargetURL(in: content) ?? "https://www.gstatic.com/generate_204"
        )
    }

    static func resolveLeafName(for name: String, groups: [String: MihomoProxyGroup], depth: Int = 0) -> String {
        guard depth < 6, let group = groups[name], let current = group.current, current.isEmpty == false else {
            return name
        }

        if current == name {
            return current
        }

        return resolveLeafName(for: current, groups: groups, depth: depth + 1)
    }

    static func measureDelay(
        for name: String,
        groups: [String: MihomoProxyGroup],
        client: MihomoControllerClient,
        targetURL: String
    ) async -> Int? {
        do {
            if groups[name] != nil {
                return try await client.testGroupDelay(
                    named: name,
                    targetURL: targetURL,
                    timeoutMilliseconds: 2_500
                )
            }

            return try await client.testProxyDelay(
                named: name,
                targetURL: targetURL,
                timeoutMilliseconds: 2_500
            )
        } catch {
            return nil
        }
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
}

struct StrategyPageView: View {
    var onShowToast: (String) -> Void = { _ in }

    @State private var showHiddenGroups = FluxBarPreferences.bool(
        for: StrategyPagePreferences.showHiddenGroupsKey,
        fallback: false
    )
    @State private var groups = StrategyConfigurationLoader.loadGroups(
        showHiddenGroups: FluxBarPreferences.bool(
            for: StrategyPagePreferences.showHiddenGroupsKey,
            fallback: false
        )
    )
    @State private var latencyRevision = 0
    @State private var activeGroupID: String?
    @State private var activeBucket: StrategyOptionBucket = .recommended
    @State private var searchKeyword = ""
    @State private var isTestingLatency = false
    @State private var resolvedLeafNames: [String: String] = [:]
    @State private var measuredLatencies: [String: Int] = [:]

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    strategyCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            FluxSheet(
                isPresented: sheetBinding,
                title: activeGroup?.name ?? "策略入口",
                subtitle: activeGroup.map { sheetSubtitle(for: $0) }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    sheetFilters
                    ScrollView(showsIndicators: false) {
                        sheetOptionsList
                    }
                    .frame(maxHeight: 560)
                }
            }
        }
        .task {
            reloadGroups()
            loadPersistedLatencies()
            await refreshResolvedState(measureLatency: false, announce: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: fluxBarConfigurationDidRefreshNotification)) { _ in
            Task {
                reloadGroups()
                loadPersistedLatencies()
                await refreshResolvedState(measureLatency: false, announce: false)
            }
        }
    }

    private var strategyCard: some View {
        FluxCard(
            title: "策略",
            trailing: {
                HStack(spacing: 8) {
                    inlineButton(
                        title: isTestingLatency ? "测试中" : "延迟测试",
                        systemImage: isTestingLatency ? "arrow.triangle.2.circlepath.circle.fill" : nil,
                        action: {
                            Task {
                                await runLatencyTest()
                            }
                        }
                    )
                    .disabled(isTestingLatency)

                    inlineIconButton(
                        systemImage: showHiddenGroups ? "eye.fill" : "eye",
                        isActive: showHiddenGroups,
                        action: {
                            toggleHiddenGroupsVisibility()
                        }
                    )

                    countBadge(groups.count)
                }
            }
        ) {
            VStack(spacing: 8) {
                ForEach(primaryDisplayGroups) { group in
                    strategyRow(group)
                }

                if showHiddenGroupsSeparator {
                    hiddenGroupDivider
                }

                ForEach(hiddenAutoDisplayGroups) { group in
                    strategyRow(group)
                }

                ForEach(hiddenFallbackDisplayGroups) { group in
                    strategyRow(group)
                }
            }
        }
    }

    private var sheetFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shouldFlattenOptionsForActiveGroup == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeGroup?.bucketOrder ?? [], id: \.self) { bucket in
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    activeBucket = bucket
                                }
                            } label: {
                                Text(bucket.rawValue)
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(activeBucket == bucket ? .white : FluxTheme.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(bucketBackground(for: bucket))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)

                TextField("筛选入口名称、地区或用途", text: $searchKeyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FluxTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
    }

    private var sheetOptionsList: some View {
        VStack(spacing: 8) {
            if filteredSheetOptions.isEmpty {
                FluxListRow(
                    icon: "🔍",
                    title: "没有匹配入口",
                    subtitle: "请调整入口分组或搜索关键字"
                ) {
                    FluxChip(title: activeBucket.rawValue, tone: .warning)
                }
            } else {
                ForEach(filteredSheetOptions) { option in
                    Button {
                        select(option: option)
                    } label: {
                        HStack(spacing: 10) {
                            Text(option.icon)
                                .font(.system(size: 17))
                                .frame(width: 38, height: 38)
                                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.white.opacity(0.82), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.05), radius: 6, y: 3)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(FluxTheme.textPrimary)
                                    .multilineTextAlignment(.leading)

                                Text(resolvedNodeName(for: option))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(FluxTheme.textSecondary)
                            }

                            Spacer(minLength: 8)

                            FluxChip(
                                title: latencyText(for: option),
                                tone: latencyTone(for: option),
                                monospace: true
                            )
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(optionBackground(isCurrent: isCurrent(option)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(isCurrent(option) ? FluxTheme.accentTop.opacity(0.34) : .white.opacity(0.86), lineWidth: 1)
                        )
                        .shadow(color: isCurrent(option) ? FluxTheme.accentTop.opacity(0.14) : Color.black.opacity(0.05), radius: isCurrent(option) ? 12 : 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var activeGroup: StrategyGroup? {
        groups.first(where: { $0.id == activeGroupID })
    }

    private var filteredSheetOptions: [StrategyOption] {
        guard let activeGroup else {
            return []
        }

        let baseOptions = shouldFlattenOptionsForActiveGroup
            ? activeGroup.options
            : activeGroup.options(in: activeBucket)
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard keyword.isEmpty == false else {
            return baseOptions
        }

        return baseOptions.filter { option in
            option.title.localizedCaseInsensitiveContains(keyword)
                || option.rawName.localizedCaseInsensitiveContains(keyword)
                || resolvedNodeName(for: option).localizedCaseInsensitiveContains(keyword)
                || (option.regionLabel?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    private var shouldFlattenOptionsForActiveGroup: Bool {
        guard let activeGroup else {
            return false
        }

        return activeGroup.rawName.contains("自动选择") || activeGroup.name.contains("自动选择")
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { activeGroupID != nil },
            set: { isPresented in
                if isPresented == false {
                    closeSheet()
                }
            }
        )
    }

    private func bucketBackground(for bucket: StrategyOptionBucket) -> some View {
        Group {
            if activeBucket == bucket {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FluxTheme.accentFill)
                    .shadow(color: FluxTheme.accentTop.opacity(0.20), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.64))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.88), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 8, y: 4)
            }
        }
    }

    private func optionBackground(isCurrent: Bool) -> some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.88, green: 0.94, blue: 1.0).opacity(0.98),
                        Color(red: 0.80, green: 0.90, blue: 1.0).opacity(0.90)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.80),
                    Color.white.opacity(0.66)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func openSheet(for groupID: String) {
        activeGroupID = groupID
        activeBucket = activeGroup?.bucketOrder.first ?? .recommended
        searchKeyword = ""
    }

    private func closeSheet() {
        activeGroupID = nil
        activeBucket = .recommended
        searchKeyword = ""
    }

    private func reloadGroups() {
        let currentSelection = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.currentOptionID) })
        let previousActiveGroupID = activeGroupID
        var nextGroups = StrategyConfigurationLoader.loadGroups(showHiddenGroups: showHiddenGroups)

        for index in nextGroups.indices {
            guard let selectedOptionID = currentSelection[nextGroups[index].id] else {
                continue
            }

            if nextGroups[index].options.contains(where: { $0.id == selectedOptionID }) {
                nextGroups[index].currentOptionID = selectedOptionID
            }
        }

        groups = nextGroups

        if let previousActiveGroupID, nextGroups.contains(where: { $0.id == previousActiveGroupID }) {
            activeGroupID = previousActiveGroupID
        } else {
            closeSheet()
        }
    }

    private func toggleHiddenGroupsVisibility() {
        showHiddenGroups.toggle()
        FluxBarPreferences.set(showHiddenGroups, for: StrategyPagePreferences.showHiddenGroupsKey)
        reloadGroups()
        Task {
            await refreshResolvedState(measureLatency: false, announce: false)
        }
        onShowToast(showHiddenGroups ? "已显示隐藏策略组" : "已隐藏自动策略组")
    }

    private var primaryDisplayGroups: [StrategyGroup] {
        guard showHiddenGroups else {
            return groups
        }
        return groups.filter { hiddenCategory(for: $0) == nil }
    }

    private var hiddenAutoDisplayGroups: [StrategyGroup] {
        guard showHiddenGroups else {
            return []
        }
        return groups.filter { hiddenCategory(for: $0) == .auto }
    }

    private var hiddenFallbackDisplayGroups: [StrategyGroup] {
        guard showHiddenGroups else {
            return []
        }
        return groups.filter { hiddenCategory(for: $0) == .fallback }
    }

    private var showHiddenGroupsSeparator: Bool {
        hiddenAutoDisplayGroups.isEmpty == false || hiddenFallbackDisplayGroups.isEmpty == false
    }

    private var hiddenGroupDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private enum HiddenGroupCategory {
        case auto
        case fallback
    }

    private func hiddenCategory(for group: StrategyGroup) -> HiddenGroupCategory? {
        let loweredRawName = group.rawName.lowercased()
        let loweredName = group.name.lowercased()

        if group.kind == .fallback
            || loweredRawName.contains("故转")
            || loweredName.contains("故转")
            || loweredRawName.contains("fallback")
            || loweredName.contains("fallback") {
            return .fallback
        }

        if group.kind == .urlTest
            || loweredRawName.contains("自动")
            || loweredName.contains("自动")
            || loweredRawName.contains("url-test")
            || loweredName.contains("url-test")
            || loweredRawName.contains("urltest")
            || loweredName.contains("urltest") {
            return .auto
        }

        return nil
    }

    private func runLatencyTest() async {
        guard isTestingLatency == false else {
            return
        }

        isTestingLatency = true
        defer { isTestingLatency = false }

        await refreshResolvedState(measureLatency: true, announce: true)
        loadPersistedLatencies()
    }

    private func select(option: StrategyOption) {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }) else {
            return
        }

        let group = groups[index]

        Task {
            guard let context = StrategyControllerLoader.context() else {
                await MainActor.run {
                    onShowToast("Controller 未就绪")
                }
                return
            }

            let client = MihomoControllerClient(configuration: context.configuration)

            do {
                try await client.selectProxy(named: option.rawName, inGroupNamed: group.rawName)

                await MainActor.run {
                    groups[index].currentOptionID = option.id
                    closeSheet()
                }

                await refreshResolvedState(measureLatency: false, announce: false)

                await MainActor.run {
                    onShowToast("已切换 \(group.name) → \(option.title)")
                }
            } catch {
                await MainActor.run {
                    onShowToast("切换策略失败")
                }
            }
        }
    }

    private func isCurrent(_ option: StrategyOption) -> Bool {
        activeGroup?.currentOptionID == option.id
    }

    private func optionSalt(for option: StrategyOption) -> Int {
        option.id.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        } % 5
    }

    private func refreshResolvedState(measureLatency: Bool, announce: Bool) async {
        guard let context = StrategyControllerLoader.context() else {
            if announce {
                onShowToast("Controller 未就绪")
            }
            return
        }

        let client = MihomoControllerClient(configuration: context.configuration)

        do {
            let controllerGroups = try await client.fetchProxyGroups()
            let groupMap = Dictionary(uniqueKeysWithValues: controllerGroups.map { ($0.name, $0) })

            var nextGroups = groups
            for index in nextGroups.indices {
                guard let current = groupMap[nextGroups[index].rawName]?.current else {
                    continue
                }

                if let option = nextGroups[index].options.first(where: { $0.rawName == current }) {
                    nextGroups[index].currentOptionID = option.id
                }
            }

            nextGroups = mergeControllerGroupsIfNeeded(
                nextGroups,
                controllerGroups: controllerGroups,
                groupMap: groupMap
            )

            var nextLeafNames: [String: String] = [:]
            for group in nextGroups {
                if let currentOption = group.currentOption() {
                    nextLeafNames[group.id] = StrategyControllerLoader.resolveLeafName(for: currentOption.rawName, groups: groupMap)
                }

                for option in group.options {
                    nextLeafNames[option.id] = StrategyControllerLoader.resolveLeafName(for: option.rawName, groups: groupMap)
                }
            }

            var nextLatencies = ProviderLatencyCacheStore.nameLatencies(
                configurationURL: FluxBarDefaultConfigurationLocator.locate()
            )
            if measureLatency {
                var refreshed: [String: Int] = [:]
                let uniqueNames = Set(nextGroups.flatMap { $0.options.map(\.rawName) })

                for name in uniqueNames {
                    if let delay = await StrategyControllerLoader.measureDelay(
                        for: name,
                        groups: groupMap,
                        client: client,
                        targetURL: context.targetURL
                    ) {
                        refreshed[name] = delay
                    }
                }

                ProviderLatencyCacheStore.mergeNamedLatencies(
                    refreshed,
                    targetURL: context.targetURL,
                    configurationURL: FluxBarDefaultConfigurationLocator.locate()
                )
                nextLatencies = refreshed
            }

            await MainActor.run {
                groups = nextGroups
                resolvedLeafNames = nextLeafNames
                measuredLatencies = nextLatencies

                if measureLatency {
                    latencyRevision += 1
                }

                if announce {
                    onShowToast(nextLatencies.isEmpty ? "延迟测试失败" : "已完成 \(nextLatencies.count) 条策略延迟测试")
                }
            }
        } catch {
            if announce {
                await MainActor.run {
                    onShowToast("策略同步失败")
                }
            }
        }
    }

    private func mergeControllerGroupsIfNeeded(
        _ source: [StrategyGroup],
        controllerGroups: [MihomoProxyGroup],
        groupMap: [String: MihomoProxyGroup]
    ) -> [StrategyGroup] {
        guard showHiddenGroups else {
            return source
        }

        var result: [StrategyGroup] = source

        for index in result.indices {
            guard result[index].options.isEmpty, let controllerGroup = groupMap[result[index].rawName] else {
                continue
            }
            result[index] = runtimeStrategyGroup(from: controllerGroup)
        }

        for controllerGroup in controllerGroups {
            guard shouldIncludeControllerHiddenGroup(controllerGroup) else {
                continue
            }

            guard result.contains(where: { $0.rawName == controllerGroup.name }) == false else {
                continue
            }

            result.append(runtimeStrategyGroup(from: controllerGroup))
        }

        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func shouldIncludeControllerHiddenGroup(_ group: MihomoProxyGroup) -> Bool {
        if group.hidden {
            return true
        }

        let loweredType = group.type.lowercased()
        if loweredType.contains("url-test") || loweredType.contains("urltest") || loweredType.contains("fallback") {
            return true
        }

        return group.name.contains("自动") || group.name.contains("故转")
    }

    private func runtimeStrategyGroup(from group: MihomoProxyGroup) -> StrategyGroup {
        let options = runtimeStrategyOptions(from: group)
        let (icon, title) = runtimeSplitLeadingSymbol(group.name)
        let currentOptionID = options.first(where: { $0.rawName == group.current })?.id
            ?? options.first?.id
            ?? group.name

        return StrategyGroup(
            id: group.name,
            rawName: group.name,
            name: title,
            icon: icon,
            kind: runtimeKind(from: group.type),
            sourceAlias: nil,
            filterAlias: nil,
            options: options,
            currentOptionID: currentOptionID
        )
    }

    private func runtimeStrategyOptions(from group: MihomoProxyGroup) -> [StrategyOption] {
        let names = group.all.isEmpty ? [group.current ?? group.name] : group.all
        return names.map { rawName in
            let (icon, title) = runtimeSplitLeadingSymbol(rawName)
            return StrategyOption(
                id: rawName,
                rawName: rawName,
                title: title,
                icon: icon,
                bucket: runtimeBucket(for: rawName),
                regionLabel: nil,
                modeLabel: "Selector",
                subtitle: "运行时策略入口",
                baseLatency: 72
            )
        }
    }

    private func runtimeKind(from rawType: String) -> StrategyGroupKind {
        let lowered = rawType.lowercased()
        if lowered.contains("url-test") || lowered.contains("urltest") {
            return .urlTest
        }
        if lowered.contains("fallback") {
            return .fallback
        }
        if lowered.contains("select") {
            return .select
        }
        return .unknown
    }

    private func runtimeBucket(for rawName: String) -> StrategyOptionBucket {
        if rawName == "直连" || rawName.contains("自动选择") || rawName.contains("全部节点") {
            return .recommended
        }
        if rawName.contains("故转") {
            return .fallback
        }
        if rawName.contains("自动") {
            return .auto
        }
        if rawName.contains("节点") {
            return .region
        }
        return .other
    }

    private func runtimeSplitLeadingSymbol(_ rawName: String) -> (String, String) {
        let parts = rawName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return ("🌐", rawName)
    }

    private func resolvedNodeName(for option: StrategyOption) -> String {
        resolvedLeafNames[option.id] ?? option.title
    }

    private func currentPathSummary(for group: StrategyGroup) -> String {
        guard let currentOption = group.currentOption() else {
            return "未选择"
        }

        let leafName = resolvedLeafNames[group.id] ?? resolvedLeafNames[currentOption.id] ?? currentOption.title
        if leafName == currentOption.title {
            return currentOption.title
        }

        return "\(currentOption.title) → \(leafName)"
    }

    private func sheetSubtitle(for group: StrategyGroup) -> String {
        guard let currentOption = group.currentOption() else {
            return "选择该策略组的出口入口"
        }

        let leafName = resolvedLeafNames[group.id] ?? resolvedLeafNames[currentOption.id] ?? currentOption.title
        if leafName == currentOption.title {
            return currentOption.title
        }

        return "\(currentOption.title) → \(leafName)"
    }

    private func latencyText(for option: StrategyOption) -> String {
        if let latency = latencyValue(for: option) {
            return "\(latency) ms"
        }

        return isTestingLatency ? "测速中" : "-- ms"
    }

    private func latencyTone(for option: StrategyOption) -> FluxTone {
        guard let latency = latencyValue(for: option) else {
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

    private func groupLatencyText(for group: StrategyGroup) -> String {
        guard let currentOption = group.currentOption() else {
            return "-- ms"
        }

        if let latency = latencyValue(for: currentOption) {
            return "\(latency) ms"
        }

        return isTestingLatency ? "测速中" : "-- ms"
    }

    private func groupLatencyTone(for group: StrategyGroup) -> FluxTone {
        guard let currentOption = group.currentOption(), let latency = latencyValue(for: currentOption) else {
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

    private func strategyRow(_ group: StrategyGroup) -> some View {
        FluxInteractiveRow(action: {
            openSheet(for: group.id)
        }) {
            HStack(spacing: 10) {
                Text(group.icon)
                    .font(.system(size: 17))
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.94, green: 0.96, blue: 1.0),
                                        Color(red: 0.87, green: 0.91, blue: 0.97)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.82), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(FluxTheme.textPrimary)

                    Text(currentPathSummary(for: group))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FluxTheme.textSecondary)
                }

                Spacer(minLength: 8)

                FluxChip(
                    title: groupLatencyText(for: group),
                    tone: groupLatencyTone(for: group),
                    monospace: true
                )
            }
        }
    }

    private func latencyValue(for option: StrategyOption) -> Int? {
        if let direct = measuredLatencies[option.rawName] {
            return direct
        }

        let leafName = resolvedNodeName(for: option)
        if leafName != option.rawName {
            return measuredLatencies[leafName]
        }

        return nil
    }

    private func loadPersistedLatencies() {
        measuredLatencies = ProviderLatencyCacheStore.nameLatencies(
            configurationURL: FluxBarDefaultConfigurationLocator.locate()
        )
    }

    private func inlineButton(title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .bold))
                }

                Text(title)
                    .font(.system(size: 12, weight: .heavy))
            }
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
                    .stroke(.white.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func inlineIconButton(systemImage: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color(red: 0.16, green: 0.25, blue: 0.37))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            isActive
                                ? AnyShapeStyle(FluxTheme.accentFill)
                                : AnyShapeStyle(
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
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func countBadge(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(Color(red: 0.20, green: 0.27, blue: 0.37))
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 8)
            .background(FluxTheme.elevatedFill, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.07), radius: 8, y: 4)
    }
}
