import Foundation

enum SubscriptionContentInspector {
    nonisolated static func inspect(data: Data) -> SubscriptionContentSummary {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines)

        var currentSection: String?
        var proxyCount = 0
        var proxyGroupCount = 0
        var ruleProviderCount = 0
        var externalController: String?
        var hasSecret = false
        var suggestedName: String?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else {
                continue
            }

            if rawLine.hasPrefix(" ") == false, rawLine.hasPrefix("\t") == false {
                if let sectionName = topLevelSectionName(in: trimmed) {
                    currentSection = sectionName
                }

                if let controller = scalarValue(for: "external-controller", in: trimmed) {
                    externalController = controller
                }

                if let secret = scalarValue(for: "secret", in: trimmed), secret.isEmpty == false {
                    hasSecret = true
                }

                if suggestedName == nil, let mixedPort = scalarValue(for: "mixed-port", in: trimmed) {
                    suggestedName = "配置 \(mixedPort)"
                }
            }

            if currentSection == "proxies", isCollectionEntry(rawLine: rawLine) {
                proxyCount += 1
            } else if currentSection == "proxy-groups", isCollectionEntry(rawLine: rawLine) {
                proxyGroupCount += 1
            } else if currentSection == "proxy-providers", isCollectionEntry(rawLine: rawLine) {
                ruleProviderCount += 1
            }
        }

        return SubscriptionContentSummary(
            proxyCount: proxyCount,
            proxyGroupCount: proxyGroupCount,
            ruleProviderCount: ruleProviderCount,
            externalController: externalController,
            hasSecret: hasSecret,
            suggestedName: suggestedName
        )
    }

    private nonisolated static func topLevelSectionName(in line: String) -> String? {
        guard line.hasSuffix(":") else {
            return nil
        }

        let sectionName = String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sectionName.isEmpty == false else {
            return nil
        }

        return sectionName
    }

    private nonisolated static func scalarValue(for key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key):") else {
            return nil
        }

        let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return cleaned.isEmpty ? nil : cleaned
    }

    private nonisolated static func isCollectionEntry(rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("- ")
    }
}
