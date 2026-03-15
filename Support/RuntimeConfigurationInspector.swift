import Foundation

enum RuntimeConfigurationInspector {
    nonisolated static func inspect(configurationURL: URL?) -> RuntimeConfigurationSnapshot {
        guard
            let configurationURL,
            let text = try? String(contentsOf: configurationURL, encoding: .utf8)
        else {
            return .unavailable
        }

        let externalController = scalarValue(for: "external-controller", in: text)
        let secret = scalarValue(for: "secret", in: text)
        let modeTitle = displayTitle(forMode: scalarValue(for: "mode", in: text))
        let tunSnapshot = tunSnapshot(in: text)

        return RuntimeConfigurationSnapshot(
            controller: controllerSnapshot(
                externalController: externalController,
                secret: secret,
                externalUIName: scalarValue(for: "external-ui-name", in: text)
            ),
            modeTitle: modeTitle,
            tun: tunSnapshot
        )
    }

    private nonisolated static func controllerSnapshot(
        externalController: String?,
        secret: String?,
        externalUIName: String?
    ) -> RuntimeControllerSnapshot {
        guard let externalController, externalController.isEmpty == false else {
            return .unavailable
        }

        let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSecret = (trimmedSecret?.isEmpty == false)
        let exposesExternally = hostExposesExternally(in: externalController)

        let accessAddress: String?
        let panelURL: URL?
        if let configuration = try? MihomoControllerConfiguration(
            controllerAddress: externalController,
            secret: trimmedSecret,
            preferLoopbackAccess: true
        ) {
            let host = configuration.apiBaseURL.host(percentEncoded: false) ?? ""
            let port = configuration.apiBaseURL.port.map(String.init) ?? ""
            accessAddress = port.isEmpty ? host : "\(host):\(port)"
            panelURL = buildPanelURL(
                apiBaseURL: configuration.apiBaseURL,
                externalUIName: externalUIName,
                secret: trimmedSecret
            )
        } else {
            accessAddress = nil
            panelURL = nil
        }

        let statusMessage: String
        switch (exposesExternally, hasSecret) {
        case (true, true):
            statusMessage = "外部控制面板已开启，已设置 secret"
        case (true, false):
            statusMessage = "外部控制面板已开启，未设置 secret"
        case (false, true):
            statusMessage = "本机控制接口已启用，已设置 secret"
        case (false, false):
            statusMessage = "本机控制接口已启用"
        }

        return RuntimeControllerSnapshot(
            bindAddress: externalController,
            accessAddress: accessAddress,
            secretValue: trimmedSecret,
            panelURL: panelURL,
            secretConfigured: hasSecret,
            exposesExternally: exposesExternally,
            statusMessage: statusMessage
        )
    }

    private nonisolated static func buildPanelURL(
        apiBaseURL: URL,
        externalUIName: String?,
        secret: String?
    ) -> URL? {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)

        let uiName = externalUIName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if uiName == "zashboard" {
            components?.path = "/ui/zashboard/"
            let host = apiBaseURL.host(percentEncoded: false) ?? "127.0.0.1"
            let port = apiBaseURL.port ?? 80
            var queryItems = [
                URLQueryItem(name: "hostname", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: apiBaseURL.scheme?.lowercased() == "https" ? "https" : "http", value: "1"),
                URLQueryItem(name: "label", value: "FluxBar")
            ]

            if let secret, secret.isEmpty == false {
                queryItems.append(URLQueryItem(name: "secret", value: secret))
            }

            components?.fragment = "/setup?" + queryItems
                .compactMap { item in
                    guard let encodedName = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                        return nil
                    }
                    let encodedValue = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    return "\(encodedName)=\(encodedValue)"
                }
                .joined(separator: "&")
        } else {
            components?.path = "/ui/"
            if let secret, secret.isEmpty == false {
                components?.queryItems = [URLQueryItem(name: "secret", value: secret)]
            }
        }

        return components?.url
    }

    private nonisolated static func scalarValue(for key: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                line.hasPrefix("#") == false
                    && line.hasPrefix("\(key):")
            }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }

    private nonisolated static func displayTitle(forMode rawValue: String?) -> String? {
        switch rawValue?.lowercased() {
        case "rule":
            return "规则"
        case "global":
            return "全局"
        case "direct":
            return "直连"
        case let value?:
            return value
        default:
            return nil
        }
    }

    private nonisolated static func hostExposesExternally(in controllerAddress: String) -> Bool {
        let address = controllerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURLString = address.contains("://") ? address : "http://\(address)"

        guard
            let url = URL(string: rawURLString),
            let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased()
        else {
            return false
        }

        switch host {
        case "127.0.0.1", "localhost", "::1", "[::1]":
            return false
        default:
            return true
        }
    }

    private nonisolated static func tunSnapshot(in text: String) -> RuntimeTUNSnapshot {
        guard let tunBlock = nestedBlock(named: "tun", in: text) else {
            return .unavailable
        }

        let enabled = nestedScalarValue(for: "enable", in: tunBlock).flatMap(parseBool) ?? false
        let stack = nestedScalarValue(for: "stack", in: tunBlock)
        let autoRoute = nestedScalarValue(for: "auto-route", in: tunBlock).flatMap(parseBool)
        let autoDetectInterface = nestedScalarValue(for: "auto-detect-interface", in: tunBlock).flatMap(parseBool)
        let dnsHijackCount = nestedListValues(for: "dns-hijack", in: tunBlock).count

        let statusMessage: String
        if enabled {
            let stackTitle = stack.map { "，stack \($0)" } ?? ""
            statusMessage = "TUN 已写入配置\(stackTitle)"
        } else {
            statusMessage = "TUN 已关闭"
        }

        return RuntimeTUNSnapshot(
            enabled: enabled,
            stack: stack,
            autoRoute: autoRoute,
            autoDetectInterface: autoDetectInterface,
            dnsHijackCount: dnsHijackCount,
            statusMessage: statusMessage
        )
    }

    private nonisolated static func nestedBlock(named key: String, in text: String) -> [String]? {
        let lines = text.components(separatedBy: .newlines)
        var block: [String] = []
        var isCapturing = false

        for line in lines {
            if isCapturing == false {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix(" ") == false, trimmed == "\(key):" {
                    isCapturing = true
                    block.append(line)
                }
                continue
            }

            if line.hasPrefix(" ") == false, line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                break
            }

            block.append(line)
        }

        return block.isEmpty ? nil : block
    }

    private nonisolated static func nestedScalarValue(for key: String, in block: [String]) -> String? {
        block.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("\(key):") }
            .map { line in
                let rawValue = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }

    private nonisolated static func nestedListValues(for key: String, in block: [String]) -> [String] {
        var values: [String] = []
        var isCapturing = false

        for line in block.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 2 {
                isCapturing = trimmed == "\(key):"
                continue
            }

            if isCapturing == false {
                continue
            }

            if indentation <= 2 {
                break
            }

            if trimmed.hasPrefix("- ") {
                values.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return values
    }

    private nonisolated static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }
}
