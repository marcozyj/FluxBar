import Foundation

actor ConfigBuilder {
    static let shared = ConfigBuilder()

    private let subscriptionService: SubscriptionService
    private let fileManager: FileManager

    init(
        subscriptionService: SubscriptionService = .shared,
        fileManager: FileManager = .default
    ) {
        self.subscriptionService = subscriptionService
        self.fileManager = fileManager
    }

    func buildConfiguration(_ request: ConfigBuildRequest) async throws -> ConfigBuildResult {
        let allSources = try await subscriptionService.listSources()
        let selectedSources = resolveSources(from: allSources, request: request)
        let documents = try await resolveDocuments(for: selectedSources, request: request)
        let primaryDocument = documents[0]
        let generatedAt = Date()

        let renderedConfiguration = renderConfiguration(
            documents: documents,
            primaryDocument: primaryDocument,
            request: request,
            generatedAt: generatedAt
        )

        let outputURL = try outputURL(for: request)
        do {
            try renderedConfiguration.write(to: outputURL, atomically: true, encoding: .utf8)
            FluxBarConfigCleanupService.pruneManagedYAMLFiles(except: [outputURL], fileManager: fileManager)
        } catch {
            throw ConfigBuilderError.outputWriteFailed(outputURL.path)
        }

        return ConfigBuildResult(
            kernel: request.kernel,
            outputURL: outputURL,
            generatedAt: generatedAt,
            sourceIDs: selectedSources.map(\.id),
            sourceNames: selectedSources.map(\.name),
            externalController: resolvedExternalController(primaryDocument: primaryDocument, overrides: request.overrides),
            secret: resolvedSecret(primaryDocument: primaryDocument, overrides: request.overrides),
            renderedConfiguration: renderedConfiguration
        )
    }

    private func resolveDocuments(
        for selectedSources: [SubscriptionSourceRecord],
        request: ConfigBuildRequest
    ) async throws -> [RawConfigDocument] {
        if selectedSources.isEmpty == false {
            return try await loadDocuments(for: selectedSources)
        }

        if let fallbackConfigurationURL = request.fallbackConfigurationURL {
            do {
                let text = try String(contentsOf: fallbackConfigurationURL, encoding: .utf8)
                let source = SubscriptionSourceRecord(
                    name: fallbackConfigurationURL.deletingPathExtension().lastPathComponent,
                    kind: .localConfig,
                    localFilePath: fallbackConfigurationURL.path,
                    isEnabled: true,
                    order: 0
                )
                return [RawConfigDocument(source: source, text: text)]
            } catch {
                throw ConfigBuilderError.fallbackConfigurationUnreadable(fallbackConfigurationURL.path)
            }
        }

        throw ConfigBuilderError.noEnabledSources
    }

    private func resolveSources(
        from sources: [SubscriptionSourceRecord],
        request: ConfigBuildRequest
    ) -> [SubscriptionSourceRecord] {
        if let sourceIDs = request.sourceIDs, sourceIDs.isEmpty == false {
            let selected = sources.filter { sourceIDs.contains($0.id) }
            return selected.sorted { lhs, rhs in
                if lhs.order == rhs.order {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.order < rhs.order
            }
        }

        return sources.filter(\.isEnabled)
    }

    private func loadDocuments(
        for sources: [SubscriptionSourceRecord]
    ) async throws -> [RawConfigDocument] {
        var documents: [RawConfigDocument] = []

        for source in sources {
            let payloadURL = try await payloadURL(for: source)

            do {
                let text = try String(contentsOf: payloadURL, encoding: .utf8)
                documents.append(RawConfigDocument(source: source, text: text))
            } catch {
                throw ConfigBuilderError.sourcePayloadUnreadable(source.name)
            }
        }

        return documents
    }

    private func payloadURL(for source: SubscriptionSourceRecord) async throws -> URL {
        do {
            return try await subscriptionService.payloadURL(for: source.id)
        } catch {
            throw ConfigBuilderError.sourcePayloadMissing(source.id)
        }
    }

    private func renderConfiguration(
        documents: [RawConfigDocument],
        primaryDocument: RawConfigDocument,
        request: ConfigBuildRequest,
        generatedAt: Date
    ) -> String {
        var renderedBlocks: [String] = []
        var emittedManagedKeys = Set<String>()

        let scalarBlocks = buildManagedScalarBlocks(primaryDocument: primaryDocument, overrides: request.overrides)
        let mergedBlocks = buildMergedBlocks(documents: documents, primaryDocument: primaryDocument, overrides: request.overrides)

        renderedBlocks.append(renderHeader(for: request.kernel, generatedAt: generatedAt, sourceNames: documents.map(\.source.name)))

        for block in primaryDocument.blocks {
            if let scalarValue = scalarBlocks[block.key], emittedManagedKeys.contains(block.key) == false {
                renderedBlocks.append(scalarValue)
                emittedManagedKeys.insert(block.key)
                continue
            }

            if let mergedValue = mergedBlocks[block.key], emittedManagedKeys.contains(block.key) == false {
                renderedBlocks.append(mergedValue)
                emittedManagedKeys.insert(block.key)
                continue
            }

            if shouldSkipOriginalBlock(key: block.key, overrides: request.overrides) {
                continue
            }

            renderedBlocks.append(block.rendered)
        }

        for key in managedKeyOrder where emittedManagedKeys.contains(key) == false {
            if let scalarValue = scalarBlocks[key] {
                renderedBlocks.append(scalarValue)
                emittedManagedKeys.insert(key)
            } else if let mergedValue = mergedBlocks[key] {
                renderedBlocks.append(mergedValue)
                emittedManagedKeys.insert(key)
            }
        }

        return renderedBlocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n\n") + "\n"
    }

    private func buildManagedScalarBlocks(
        primaryDocument: RawConfigDocument,
        overrides: ConfigBuildOverrides
    ) -> [String: String] {
        var blocks: [String: String] = [:]

        let mixedPort = overrides.mixedPort ?? intScalarValue(for: "mixed-port", in: primaryDocument) ?? 7890
        blocks["mixed-port"] = renderScalarBlock(key: "mixed-port", value: String(mixedPort))

        if let httpPort = overrides.httpPort ?? intScalarValue(for: "port", in: primaryDocument) {
            blocks["port"] = renderScalarBlock(key: "port", value: String(httpPort))
        }

        if let socksPort = overrides.socksPort ?? intScalarValue(for: "socks-port", in: primaryDocument) {
            blocks["socks-port"] = renderScalarBlock(key: "socks-port", value: String(socksPort))
        }

        if let redirPort = overrides.redirPort ?? intScalarValue(for: "redir-port", in: primaryDocument) {
            blocks["redir-port"] = renderScalarBlock(key: "redir-port", value: String(redirPort))
        }

        if let tproxyPort = overrides.tproxyPort ?? intScalarValue(for: "tproxy-port", in: primaryDocument) {
            blocks["tproxy-port"] = renderScalarBlock(key: "tproxy-port", value: String(tproxyPort))
        }

        let mode = overrides.mode?.rawValue
            ?? scalarValue(for: "mode", in: primaryDocument)
            ?? ConfigProxyMode.rule.rawValue
        blocks["mode"] = renderScalarBlock(key: "mode", value: mode)

        let allowLAN = overrides.allowLAN ?? boolScalarValue(for: "allow-lan", in: primaryDocument) ?? false
        blocks["allow-lan"] = renderScalarBlock(key: "allow-lan", value: allowLAN ? "true" : "false")

        if let bindAddress = normalizedNonEmpty(overrides.bindAddress) ?? scalarValue(for: "bind-address", in: primaryDocument) {
            blocks["bind-address"] = renderScalarBlock(key: "bind-address", value: quoteIfNeeded(bindAddress))
        }

        let externalController = resolvedExternalController(primaryDocument: primaryDocument, overrides: overrides)
        if let externalController {
            let renderedValue = externalController.isEmpty ? "\"\"" : quoteIfNeeded(externalController)
            blocks["external-controller"] = renderScalarBlock(key: "external-controller", value: renderedValue)
        }

        if let secret = resolvedSecret(primaryDocument: primaryDocument, overrides: overrides) {
            blocks["secret"] = renderScalarBlock(key: "secret", value: quoteIfNeeded(secret))
        }

        if overrides.externalControllerCORS != nil || primaryDocument.blockMap["external-controller-cors"] != nil {
            let patchedCORSBlock = patchExternalControllerCORSBlock(
                existingBlock: primaryDocument.blockMap["external-controller-cors"],
                overrides: overrides.externalControllerCORS
            )
            blocks["external-controller-cors"] = patchedCORSBlock
        }

        let logLevel = overrides.logLevel?.rawValue
            ?? scalarValue(for: "log-level", in: primaryDocument)
            ?? ConfigLogLevel.info.rawValue
        blocks["log-level"] = renderScalarBlock(key: "log-level", value: logLevel)

        if let ipv6 = overrides.ipv6 ?? boolScalarValue(for: "ipv6", in: primaryDocument) {
            blocks["ipv6"] = renderScalarBlock(key: "ipv6", value: ipv6 ? "true" : "false")
        }

        if overrides.tunEnabled != nil || overrides.tun != nil {
            let patchedTunBlock = patchTunBlock(
                existingBlock: primaryDocument.blockMap["tun"],
                overrides: overrides
            )
            blocks["tun"] = patchedTunBlock
        }

        return blocks
    }

    private func buildMergedBlocks(
        documents: [RawConfigDocument],
        primaryDocument: RawConfigDocument,
        overrides: ConfigBuildOverrides
    ) -> [String: String] {
        var blocks: [String: String] = [:]

        let proxyItems = mergeListItems(section: "proxies", in: documents)
        if proxyItems.isEmpty == false {
            blocks["proxies"] = renderListBlock(key: "proxies", items: proxyItems)
        }

        let proxyGroupItems = mergeListItems(section: "proxy-groups", in: documents)
        if proxyGroupItems.isEmpty == false {
            blocks["proxy-groups"] = renderListBlock(key: "proxy-groups", items: proxyGroupItems)
        }

        let proxyProviderEntries = mergeMapEntries(section: "proxy-providers", in: documents)
        if proxyProviderEntries.isEmpty == false {
            blocks["proxy-providers"] = renderMapBlock(key: "proxy-providers", entries: proxyProviderEntries)
        }

        let ruleProviderEntries = mergeMapEntries(section: "rule-providers", in: documents)
        if ruleProviderEntries.isEmpty == false {
            blocks["rule-providers"] = renderMapBlock(key: "rule-providers", entries: ruleProviderEntries)
        }

        let ruleItems = mergeListItems(section: "rules", in: documents)
        if ruleItems.isEmpty == false {
            blocks["rules"] = renderListBlock(key: "rules", items: ruleItems)
        }

        if overrides.tunEnabled == nil, overrides.tun == nil, let existingTun = primaryDocument.blockMap["tun"] {
            blocks["tun"] = existingTun.rendered
        }

        return blocks
    }

    private func shouldSkipOriginalBlock(key: String, overrides: ConfigBuildOverrides) -> Bool {
        if managedKeyOrder.contains(key) {
            return true
        }

        if key == "tun", overrides.tunEnabled != nil || overrides.tun != nil {
            return true
        }

        return false
    }

    private func outputURL(for request: ConfigBuildRequest) throws -> URL {
        let directoryURL = try FluxBarStorageDirectories.configsRoot(fileManager: fileManager)
        let fileName = sanitizedFileName(
            request.preferredFileName ?? "fluxbar-\(request.kernel.rawValue).yaml"
        )
        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func resolvedExternalController(
        primaryDocument: RawConfigDocument,
        overrides: ConfigBuildOverrides
    ) -> String? {
        if let enabled = overrides.externalControllerEnabled, enabled == false {
            return normalizedNonEmpty(overrides.externalController) ?? "127.0.0.1:19090"
        }

        return normalizedNonEmpty(overrides.externalController)
            ?? scalarValue(for: "external-controller", in: primaryDocument)
            ?? "127.0.0.1:19090"
    }

    private func resolvedSecret(
        primaryDocument: RawConfigDocument,
        overrides: ConfigBuildOverrides
    ) -> String? {
        normalizedNonEmpty(overrides.secret)
            ?? scalarValue(for: "secret", in: primaryDocument)
    }

    private func patchTunBlock(existingBlock: RawConfigBlock?, overrides: ConfigBuildOverrides) -> String {
        let tunOverrides = overrides.tun
        let enabled = overrides.tunEnabled ?? tunOverrides?.enabled ?? boolValue(for: "enable", inNestedBlock: existingBlock) ?? false
        let stack = tunOverrides?.stack?.rawValue ?? nestedScalarValue(for: "stack", in: existingBlock) ?? ConfigTUNStack.system.rawValue
        let autoRoute = tunOverrides?.autoRoute ?? boolValue(for: "auto-route", inNestedBlock: existingBlock) ?? true
        let autoDetectInterface = tunOverrides?.autoDetectInterface ?? boolValue(for: "auto-detect-interface", inNestedBlock: existingBlock) ?? true
        let strictRoute = tunOverrides?.strictRoute ?? boolValue(for: "strict-route", inNestedBlock: existingBlock) ?? false
        let dnsHijack = normalizedDNSHijack(
            overrides: tunOverrides?.dnsHijack,
            existingBlock: existingBlock
        )

        var lines = [
            "tun:",
            "  enable: \(enabled ? "true" : "false")",
            "  stack: \(stack)",
            "  auto-route: \(autoRoute ? "true" : "false")",
            "  auto-detect-interface: \(autoDetectInterface ? "true" : "false")"
        ]

        if strictRoute || nestedScalarValue(for: "strict-route", in: existingBlock) != nil {
            lines.append("  strict-route: \(strictRoute ? "true" : "false")")
        }

        if dnsHijack.isEmpty == false {
            lines.append("  dns-hijack:")
            lines.append(contentsOf: dnsHijack.map { "    - \($0)" })
        }

        appendNestedTunLines(from: existingBlock, into: &lines)
        return lines.joined(separator: "\n")
    }

    private func patchExternalControllerCORSBlock(
        existingBlock: RawConfigBlock?,
        overrides: ConfigExternalControllerCORSOverrides?
    ) -> String {
        let allowPrivateNetwork = overrides?.allowPrivateNetwork
            ?? boolValue(for: "allow-private-network", inNestedBlock: existingBlock)
            ?? true
        let allowOrigins = normalizedAllowOrigins(overrides: overrides?.allowOrigins, existingBlock: existingBlock)

        var lines = [
            "external-controller-cors:",
            "  allow-private-network: \(allowPrivateNetwork ? "true" : "false")",
            "  allow-origins:"
        ]

        if allowOrigins.isEmpty {
            lines.append("    - \"*\"")
        } else {
            lines.append(contentsOf: allowOrigins.map { "    - \(quoteIfNeeded($0))" })
        }

        return lines.joined(separator: "\n")
    }

    private func appendNestedTunLines(from existingBlock: RawConfigBlock?, into lines: inout [String]) {
        guard let existingBlock else {
            return
        }

        let managedKeys: Set<String> = [
            "enable",
            "stack",
            "auto-route",
            "auto-detect-interface",
            "strict-route",
            "dns-hijack"
        ]

        var skippingNestedList = false

        for line in existingBlock.bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 2, let key = nestedKey(from: trimmed) {
                skippingNestedList = key == "dns-hijack"

                if managedKeys.contains(key) {
                    continue
                }

                lines.append(line)
                continue
            }

            if skippingNestedList {
                if indentation > 2 {
                    continue
                }
                skippingNestedList = false
            }

            lines.append(line)
        }
    }

    private func mergeListItems(
        section: String,
        in documents: [RawConfigDocument]
    ) -> [[String]] {
        var seen = Set<String>()
        var merged: [[String]] = []

        for document in documents {
            guard let block = document.blockMap[section] else {
                continue
            }

            for item in splitListItems(from: block) {
                let identity = listItemIdentity(section: section, itemLines: item)
                guard seen.contains(identity) == false else {
                    continue
                }
                seen.insert(identity)
                merged.append(item)
            }
        }

        return merged
    }

    private func mergeMapEntries(
        section: String,
        in documents: [RawConfigDocument]
    ) -> [[String]] {
        var seen = Set<String>()
        var merged: [[String]] = []

        for document in documents {
            guard let block = document.blockMap[section] else {
                continue
            }

            for entry in splitMapEntries(from: block) {
                let key = mapEntryKey(entry) ?? UUID().uuidString
                guard seen.contains(key) == false else {
                    continue
                }
                seen.insert(key)
                merged.append(entry)
            }
        }

        return merged
    }

    private func splitListItems(from block: RawConfigBlock) -> [[String]] {
        var items: [[String]] = []
        var current: [String] = []

        for line in block.bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 2, trimmed.hasPrefix("- ") {
                if current.isEmpty == false {
                    items.append(current)
                }
                current = [line]
            } else if current.isEmpty == false {
                current.append(line)
            }
        }

        if current.isEmpty == false {
            items.append(current)
        }

        return items
    }

    private func splitMapEntries(from block: RawConfigBlock) -> [[String]] {
        var entries: [[String]] = []
        var current: [String] = []

        for line in block.bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 2, trimmed.hasSuffix(":"), trimmed.hasPrefix("- ") == false {
                if current.isEmpty == false {
                    entries.append(current)
                }
                current = [line]
            } else if current.isEmpty == false {
                current.append(line)
            }
        }

        if current.isEmpty == false {
            entries.append(current)
        }

        return entries
    }

    private func listItemIdentity(section: String, itemLines: [String]) -> String {
        if section == "rules" {
            return itemLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        }

        for line in itemLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("- name:") {
                return String(trimmed.dropFirst("- name:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }

            if trimmed.hasPrefix("name:") {
                return String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }

        return itemLines.joined(separator: "\n")
    }

    private func mapEntryKey(_ entryLines: [String]) -> String? {
        guard let firstLine = entryLines.first else {
            return nil
        }

        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(":") else {
            return nil
        }

        return String(trimmed.dropLast())
    }

    private func renderListBlock(key: String, items: [[String]]) -> String {
        ([ "\(key):" ] + items.flatMap { $0 }).joined(separator: "\n")
    }

    private func renderMapBlock(key: String, entries: [[String]]) -> String {
        ([ "\(key):" ] + entries.flatMap { $0 }).joined(separator: "\n")
    }

    private func renderScalarBlock(key: String, value: String) -> String {
        "\(key): \(value)"
    }

    private func renderHeader(for kernel: KernelType, generatedAt: Date, sourceNames: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        let joinedSources = sourceNames.joined(separator: ", ")
        return [
            "# Generated by FluxBar",
            "# Kernel: \(kernel.displayName)",
            "# Time: \(formatter.string(from: generatedAt))",
            "# Sources: \(joinedSources)"
        ].joined(separator: "\n")
    }

    private func scalarValue(for key: String, in document: RawConfigDocument) -> String? {
        guard let block = document.blockMap[key] else {
            return nil
        }

        return normalizedNonEmpty(block.scalarValue)
    }

    private func intScalarValue(for key: String, in document: RawConfigDocument) -> Int? {
        guard let rawValue = scalarValue(for: key, in: document) else {
            return nil
        }

        return Int(rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    private func boolScalarValue(for key: String, in document: RawConfigDocument) -> Bool? {
        guard let rawValue = scalarValue(for: key, in: document)?.lowercased() else {
            return nil
        }

        switch rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func quoteIfNeeded(_ value: String) -> String {
        let normalized = normalizedScalar(value)

        let needsQuotingByPrefix = normalized.hasPrefix("-")
            || normalized.hasPrefix("?")
            || normalized.hasPrefix(":")
            || normalized.hasPrefix("*")
            || normalized.hasPrefix("&")
            || normalized.hasPrefix("!")
            || normalized.hasPrefix("@")
            || normalized.hasPrefix("`")
        let needsQuotingByContent = normalized.rangeOfCharacter(
            from: CharacterSet(charactersIn: ":\n\r\t #{}[],&*!|>'\"%@`")
        ) != nil
        let reservedScalars: Set<String> = [
            "y", "yes", "n", "no", "true", "false", "on", "off", "null", "~"
        ]
        let needsQuotingByReservedWord = reservedScalars.contains(normalized.lowercased())

        if needsQuotingByPrefix || needsQuotingByContent || needsQuotingByReservedWord {
            let escaped = normalized
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        return normalized
    }


    private func sanitizedFileName(_ fileName: String) -> String {
        let basename = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension.isEmpty ? "yaml" : URL(fileURLWithPath: fileName).pathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalized = basename.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return "\(normalizedNonEmpty(normalized) ?? "fluxbar-config").\(ext)"
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalized = normalizedScalar(value)
        guard normalized.isEmpty == false else {
            return nil
        }

        return normalized
    }

    private func nestedScalarValue(for key: String, in block: RawConfigBlock?) -> String? {
        guard let block else {
            return nil
        }

        return block.bodyLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("\(key):") }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizedScalar(rawValue)
            }
    }

    private func boolValue(for key: String, inNestedBlock block: RawConfigBlock?) -> Bool? {
        guard let rawValue = nestedScalarValue(for: key, in: block)?.lowercased() else {
            return nil
        }

        switch rawValue {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func nestedKey(from trimmedLine: String) -> String? {
        guard let separatorIndex = trimmedLine.firstIndex(of: ":") else {
            return nil
        }

        let key = String(trimmedLine[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func normalizedDNSHijack(overrides: [String]?, existingBlock: RawConfigBlock?) -> [String] {
        if let overrides {
            return overrides.filter { $0.isEmpty == false }
        }

        guard let existingBlock else {
            return ["any:53"]
        }

        var values: [String] = []
        var isInDNSHijack = false

        for line in existingBlock.bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 2 {
                isInDNSHijack = trimmed == "dns-hijack:"
                continue
            }

            if isInDNSHijack, indentation > 2, trimmed.hasPrefix("- ") {
                values.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return values.isEmpty ? ["any:53"] : values
    }

    private func normalizedAllowOrigins(overrides: [String]?, existingBlock: RawConfigBlock?) -> [String] {
        if let overrides {
            return overrides
                .map { normalizedScalar($0) }
                .filter { $0.isEmpty == false }
        }

        guard let existingBlock else {
            return []
        }

        var values: [String] = []
        var isInAllowOrigins = false

        for line in existingBlock.bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 2 {
                isInAllowOrigins = trimmed == "allow-origins:"
                continue
            }

            if isInAllowOrigins, indentation > 2, trimmed.hasPrefix("- ") {
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = normalizedScalar(value)
                if normalized.isEmpty == false {
                    values.append(normalized)
                }
            }
        }

        return values
    }

    private func normalizedScalar(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count >= 2 {
            let hasDoubleQuotes = result.hasPrefix("\"") && result.hasSuffix("\"")
            let hasSingleQuotes = result.hasPrefix("'") && result.hasSuffix("'")

            if hasDoubleQuotes || hasSingleQuotes {
                result.removeFirst()
                result.removeLast()
            }
        }

        result = result
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private let managedKeyOrder = [
        "mixed-port",
        "port",
        "socks-port",
        "redir-port",
        "tproxy-port",
        "mode",
        "allow-lan",
        "bind-address",
        "external-controller",
        "secret",
        "external-controller-cors",
        "log-level",
        "ipv6",
        "tun",
        "proxies",
        "proxy-groups",
        "proxy-providers",
        "rule-providers",
        "rules"
    ]
}

private struct RawConfigDocument {
    let source: SubscriptionSourceRecord
    let blocks: [RawConfigBlock]
    let blockMap: [String: RawConfigBlock]

    nonisolated init(source: SubscriptionSourceRecord, text: String) {
        self.source = source

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")

        var parsedBlocks: [RawConfigBlock] = []
        var currentKey: String?
        var currentLines: [String] = []

        func flushCurrentBlock() {
            guard let currentKey, currentLines.isEmpty == false else {
                return
            }
            parsedBlocks.append(RawConfigBlock(key: currentKey, lines: currentLines))
        }

        for line in lines {
            if let key = Self.topLevelKey(in: line) {
                flushCurrentBlock()
                currentKey = key
                currentLines = [line]
                continue
            }

            if currentKey != nil {
                currentLines.append(line)
            }
        }

        flushCurrentBlock()
        self.blocks = parsedBlocks
        self.blockMap = Dictionary(uniqueKeysWithValues: parsedBlocks.map { ($0.key, $0) })
    }

    private nonisolated static func topLevelKey(in line: String) -> String? {
        guard line.hasPrefix(" ") == false, line.hasPrefix("\t") == false else {
            return nil
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else {
            return nil
        }

        guard let separatorIndex = trimmed.firstIndex(of: ":") else {
            return nil
        }

        let key = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

private struct RawConfigBlock {
    let key: String
    let lines: [String]

    nonisolated var bodyLines: [String] {
        Array(lines.dropFirst())
    }

    nonisolated var rendered: String {
        lines.joined(separator: "\n")
    }

    nonisolated var scalarValue: String? {
        guard let firstLine = lines.first, let separatorIndex = firstLine.firstIndex(of: ":") else {
            return nil
        }

        let rawValue = firstLine[firstLine.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue.isEmpty ? nil : rawValue
    }
}
