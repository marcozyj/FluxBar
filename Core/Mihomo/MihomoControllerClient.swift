import Foundation

actor MihomoControllerClient {
    private let configuration: MihomoControllerConfiguration
    private let session: URLSession
    private let jsonDecoder: JSONDecoder

    init(
        configuration: MihomoControllerConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = decoder
    }

    func fetchVersion() async throws -> MihomoVersionInfo {
        let data = try await data(for: "/version")
        return try Self.decodeVersion(from: data)
    }

    func fetchProxyGroups() async throws -> [MihomoProxyGroup] {
        let data = try await data(for: "/group")
        return try Self.decodeProxyGroups(from: data, path: "/group")
    }

    func fetchProxyGroup(named name: String) async throws -> MihomoProxyGroup {
        let path = "/group/\(Self.escapePathComponent(name))"
        let data = try await data(for: path)
        return try Self.decodeSingleProxyGroup(from: data, path: path)
    }

    func fetchProxyNodes() async throws -> [MihomoProxyNode] {
        let data = try await data(for: "/proxies")
        return try Self.decodeProxyNodes(from: data, path: "/proxies")
    }

    func selectProxy(named proxyName: String, inGroupNamed groupName: String) async throws {
        let path = "/proxies/\(Self.escapePathComponent(groupName))"
        let payload = try JSONSerialization.data(withJSONObject: ["name": proxyName])
        _ = try await data(for: path, method: "PUT", body: payload)
    }

    func testProxyDelay(
        named proxyName: String,
        targetURL: String,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Int? {
        let path = "/proxies/\(Self.escapePathComponent(proxyName))/delay"
        let data = try await data(
            for: path,
            queryItems: [
                URLQueryItem(name: "url", value: targetURL),
                URLQueryItem(name: "timeout", value: String(timeoutMilliseconds))
            ]
        )
        return try Self.decodeDelay(from: data, path: path)
    }

    func testGroupDelay(
        named groupName: String,
        targetURL: String,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Int? {
        let path = "/group/\(Self.escapePathComponent(groupName))/delay"
        let data = try await data(
            for: path,
            queryItems: [
                URLQueryItem(name: "url", value: targetURL),
                URLQueryItem(name: "timeout", value: String(timeoutMilliseconds))
            ]
        )
        return try Self.decodeDelay(from: data, path: path)
    }

    func fetchRules() async throws -> [MihomoRule] {
        let data = try await data(for: "/rules")
        return try Self.decodeRules(from: data, path: "/rules")
    }

    func fetchConnections() async throws -> MihomoConnectionsSnapshot {
        let data = try await data(for: "/connections")
        return try Self.decodeConnections(from: data, path: "/connections")
    }

    func closeAllConnections() async throws {
        _ = try await data(for: "/connections", method: "DELETE")
    }

    func closeConnection(id: String) async throws {
        let path = "/connections/\(Self.escapePathComponent(id))"
        _ = try await data(for: path, method: "DELETE")
    }

    func fetchTrafficSnapshot() async throws -> MihomoTrafficSnapshot {
        let data = try await data(for: "/traffic")
        return try Self.decodeTraffic(from: data, path: "/traffic")
    }

    func patchTunConfiguration(
        enabled: Bool,
        stack: String?,
        autoRoute: Bool?,
        autoDetectInterface: Bool?,
        strictRoute: Bool?,
        dnsHijack: [String]?,
        enableDNS: Bool?
    ) async throws {
        var tunBody: [String: Any] = ["enable": enabled]

        if let stack, stack.isEmpty == false {
            tunBody["stack"] = stack
        }
        if let autoRoute {
            tunBody["auto-route"] = autoRoute
        }
        if let autoDetectInterface {
            tunBody["auto-detect-interface"] = autoDetectInterface
        }
        if let strictRoute {
            tunBody["strict-route"] = strictRoute
        }
        if let dnsHijack {
            tunBody["dns-hijack"] = dnsHijack
        }

        var body: [String: Any] = ["tun": tunBody]
        if let enableDNS {
            body["dns"] = ["enable": enableDNS]
        }

        try await patchConfigs(body: body)
    }

    func fetchRuntimeTunEnabled() async throws -> Bool? {
        let data = try await data(for: "/configs")
        return try Self.decodeRuntimeTunEnabled(from: data, path: "/configs")
    }

    func fetchLiveTrafficSnapshot(timeoutNanoseconds: UInt64 = 1_500_000_000) async throws -> MihomoTrafficSnapshot {
        let stream = try streamTraffic()

        return try await withThrowingTaskGroup(of: MihomoTrafficSnapshot.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let snapshot = try await iterator.next() else {
                    throw MihomoControllerError.transport(path: "/traffic", message: "traffic stream ended before first snapshot")
                }
                return snapshot
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MihomoControllerError.transport(path: "/traffic", message: "timed out waiting for traffic snapshot")
            }

            let snapshot = try await group.next()!
            group.cancelAll()
            return snapshot
        }
    }

    func streamLogs(level: MihomoLogLevel = .info) throws -> AsyncThrowingStream<MihomoLogEntry, Error> {
        let request = try webSocketRequest(
            path: "/logs",
            queryItems: level == .unknown ? [] : [URLQueryItem(name: "level", value: level.rawValue)]
        )

        return AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: request)
            task.resume()

            @Sendable func receiveNext() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        do {
                            let data = try Self.webSocketData(from: message)
                            let entry = try Self.decodeLogEntry(from: data, path: "/logs")
                            continuation.yield(entry)
                            receiveNext()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    case .failure(let error):
                        continuation.finish(
                            throwing: MihomoControllerError.transport(path: "/logs", message: error.localizedDescription)
                        )
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            receiveNext()
        }
    }

    func streamTraffic() throws -> AsyncThrowingStream<MihomoTrafficSnapshot, Error> {
        let request = try webSocketRequest(path: "/traffic")

        return AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: request)
            task.resume()

            @Sendable func receiveNext() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        do {
                            let data = try Self.webSocketData(from: message)
                            let snapshot = try Self.decodeTraffic(from: data, path: "/traffic")
                            continuation.yield(snapshot)
                            receiveNext()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    case .failure(let error):
                        continuation.finish(
                            throwing: MihomoControllerError.transport(path: "/traffic", message: error.localizedDescription)
                        )
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            receiveNext()
        }
    }

    func streamConnections(intervalMilliseconds: Int = 1_000) throws -> AsyncThrowingStream<MihomoConnectionsSnapshot, Error> {
        let request = try webSocketRequest(
            path: "/connections",
            queryItems: [URLQueryItem(name: "interval", value: String(intervalMilliseconds))]
        )

        return AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: request)
            task.resume()

            @Sendable func receiveNext() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        do {
                            let data = try Self.webSocketData(from: message)
                            let snapshot = try Self.decodeConnections(from: data, path: "/connections")
                            continuation.yield(snapshot)
                            receiveNext()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    case .failure(let error):
                        continuation.finish(
                            throwing: MihomoControllerError.transport(path: "/connections", message: error.localizedDescription)
                        )
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }

            receiveNext()
        }
    }

    private func data(
        for path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        let request = try request(path: path, method: method, queryItems: queryItems, body: body)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MihomoControllerError.transport(path: path, message: "未收到 HTTP 响应")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MihomoControllerError.invalidResponse(
                path: path,
                statusCode: httpResponse.statusCode,
                body: message
            )
        }

        return data
    }

    private func patchConfigs(body: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw MihomoControllerError.malformedPayload(path: "/configs")
        }

        let payload = try JSONSerialization.data(withJSONObject: body)
        _ = try await data(for: "/configs", method: "PATCH", body: payload)
    }

    private func request(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?
    ) throws -> URLRequest {
        let url = try Self.makeURL(
            baseURL: configuration.apiBaseURL,
            path: path,
            queryItems: queryItems
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let secret = configuration.secret, secret.isEmpty == false {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func webSocketRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw MihomoControllerError.invalidControllerAddress(configuration.bindAddress)
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let url = try Self.makeURL(components: components, path: path, queryItems: queryItems)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let secret = configuration.secret, secret.isEmpty == false {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private nonisolated static func makeURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MihomoControllerError.invalidControllerAddress(baseURL.absoluteString)
        }

        return try makeURL(components: components, path: path, queryItems: queryItems)
    }

    private nonisolated static func makeURL(
        components: URLComponents,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard path.hasPrefix("/") else {
            throw MihomoControllerError.invalidRequestPath(path)
        }

        var components = components
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, requestPath].filter { $0.isEmpty == false }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw MihomoControllerError.invalidRequestPath(path)
        }

        return url
    }

    private nonisolated static func escapePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private nonisolated static func webSocketData(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            throw MihomoControllerError.malformedPayload(path: "ws")
        }
    }

    private nonisolated static func decodeVersion(from data: Data) throws -> MihomoVersionInfo {
        let object = try jsonObject(from: data, path: "/version")
        guard let dictionary = object as? [String: Any] else {
            throw MihomoControllerError.malformedPayload(path: "/version")
        }

        let version = stringValue(dictionary["version"]) ?? stringValue(dictionary["Version"]) ?? "unknown"
        return MihomoVersionInfo(
            version: version,
            meta: boolValue(dictionary["meta"]),
            premium: boolValue(dictionary["premium"])
        )
    }

    private nonisolated static func decodeProxyGroups(from data: Data, path: String) throws -> [MihomoProxyGroup] {
        let object = try jsonObject(from: data, path: path)
        let groups = dictionaries(from: object, preferredKeys: ["groups", "proxies"])
            .compactMap { dictionary in
                proxyGroup(from: dictionary)
            }

        if groups.isEmpty, let single = object as? [String: Any], let group = proxyGroup(from: single) {
            return [group]
        }

        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func decodeSingleProxyGroup(from data: Data, path: String) throws -> MihomoProxyGroup {
        let groups = try decodeProxyGroups(from: data, path: path)
        guard let first = groups.first else {
            throw MihomoControllerError.malformedPayload(path: path)
        }
        return first
    }

    private nonisolated static func decodeProxyNodes(from data: Data, path: String) throws -> [MihomoProxyNode] {
        let object = try jsonObject(from: data, path: path)
        let nodes = dictionaries(from: object, preferredKeys: ["proxies"])
            .compactMap { dictionary in
                proxyNode(from: dictionary)
            }

        return nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func decodeDelay(from data: Data, path: String) throws -> Int? {
        let object = try jsonObject(from: data, path: path)
        guard let dictionary = object as? [String: Any] else {
            throw MihomoControllerError.malformedPayload(path: path)
        }

        return intValue(dictionary["delay"]) ?? intValue(dictionary["Delay"])
    }

    private nonisolated static func decodeRules(from data: Data, path: String) throws -> [MihomoRule] {
        let object = try jsonObject(from: data, path: path)
        guard
            let dictionary = object as? [String: Any],
            let ruleItems = dictionary["rules"] as? [Any]
        else {
            throw MihomoControllerError.malformedPayload(path: path)
        }

        return ruleItems.compactMap { item in
            guard let rule = item as? [String: Any] else {
                return nil
            }

            let type = stringValue(rule["type"]) ?? "UNKNOWN"
            let payload = stringValue(rule["payload"]) ?? stringValue(rule["rule"]) ?? "*"
            let proxy = stringValue(rule["proxy"]) ?? stringValue(rule["adapter"]) ?? "DIRECT"
            let provider = stringValue(rule["provider"])

            return MihomoRule(
                id: "\(type)-\(payload)-\(proxy)",
                type: type,
                payload: payload,
                proxy: proxy,
                provider: provider
            )
        }
    }

    private nonisolated static func decodeConnections(from data: Data, path: String) throws -> MihomoConnectionsSnapshot {
        let object = try jsonObject(from: data, path: path)
        guard let dictionary = object as? [String: Any] else {
            throw MihomoControllerError.malformedPayload(path: path)
        }

        let connections = (dictionary["connections"] as? [Any] ?? []).compactMap { item -> MihomoConnection? in
            guard let raw = item as? [String: Any] else {
                return nil
            }

            let metadataDictionary = raw["metadata"] as? [String: Any] ?? [:]

            let metadata = MihomoConnectionMetadata(
                network: stringValue(metadataDictionary["network"]),
                type: stringValue(metadataDictionary["type"]),
                sourceIP: stringValue(metadataDictionary["sourceIP"]),
                sourcePort: intValue(metadataDictionary["sourcePort"]),
                destinationIP: stringValue(metadataDictionary["destinationIP"]),
                destinationPort: stringValue(metadataDictionary["destinationPort"]),
                host: stringValue(metadataDictionary["host"]),
                process: stringValue(metadataDictionary["process"]),
                processPath: stringValue(metadataDictionary["processPath"])
            )

            return MihomoConnection(
                id: stringValue(raw["id"]) ?? UUID().uuidString,
                uploadBytes: int64Value(raw["upload"]) ?? 0,
                downloadBytes: int64Value(raw["download"]) ?? 0,
                start: dateValue(raw["start"]),
                chains: stringArrayValue(raw["chains"]),
                rule: stringValue(raw["rule"]),
                rulePayload: stringValue(raw["rulePayload"]),
                metadata: metadata
            )
        }

        return MihomoConnectionsSnapshot(
            uploadTotalBytes: int64Value(dictionary["uploadTotal"]) ?? 0,
            downloadTotalBytes: int64Value(dictionary["downloadTotal"]) ?? 0,
            connections: connections,
            memoryBytes: int64Value(dictionary["memory"])
        )
    }

    private nonisolated static func decodeTraffic(from data: Data, path: String) throws -> MihomoTrafficSnapshot {
        let object = try jsonObject(from: data, path: path)
        guard let dictionary = object as? [String: Any] else {
            throw MihomoControllerError.malformedPayload(path: path)
        }

        guard
            let up = doubleValue(dictionary["up"]),
            let down = doubleValue(dictionary["down"])
        else {
            throw MihomoControllerError.missingField(path: path, field: "up/down")
        }

        return MihomoTrafficSnapshot(
            up: up,
            down: down,
            upTotal: int64Value(dictionary["upTotal"]) ?? 0,
            downTotal: int64Value(dictionary["downTotal"]) ?? 0
        )
    }

    private nonisolated static func decodeLogEntry(from data: Data, path: String) throws -> MihomoLogEntry {
        let object = try jsonObject(from: data, path: path)
        guard let dictionary = object as? [String: Any] else {
            throw MihomoControllerError.malformedPayload(path: path)
        }

        let rawLevel = stringValue(dictionary["type"])?.lowercased() ?? "unknown"
        let level = MihomoLogLevel(rawValue: rawLevel) ?? .unknown
        let payload = stringValue(dictionary["payload"]) ?? stringValue(dictionary["message"]) ?? ""

        return MihomoLogEntry(level: level, payload: payload)
    }

    private nonisolated static func decodeRuntimeTunEnabled(from data: Data, path: String) throws -> Bool? {
        let object = try jsonObject(from: data, path: path)
        guard let dictionary = object as? [String: Any] else {
            throw MihomoControllerError.malformedPayload(path: path)
        }

        if let tun = dictionary["tun"] as? [String: Any] {
            return boolValue(tun["enable"])
        }

        return boolValue(dictionary["tun"])
    }

    private nonisolated static func proxyGroup(from dictionary: [String: Any]) -> MihomoProxyGroup? {
        let candidates = stringArrayValue(dictionary["all"])
        guard candidates.isEmpty == false || stringValue(dictionary["now"]) != nil || stringValue(dictionary["current"]) != nil else {
            return nil
        }

        let name = stringValue(dictionary["name"]) ?? stringValue(dictionary["Name"]) ?? "Unknown"
        return MihomoProxyGroup(
            id: name,
            name: name,
            type: stringValue(dictionary["type"]) ?? "Selector",
            current: stringValue(dictionary["now"]) ?? stringValue(dictionary["current"]),
            all: candidates,
            icon: stringValue(dictionary["icon"]),
            hidden: boolValue(dictionary["hidden"]) ?? false,
            history: historySamples(from: dictionary["history"])
        )
    }

    private nonisolated static func proxyNode(from dictionary: [String: Any]) -> MihomoProxyNode? {
        if stringArrayValue(dictionary["all"]).isEmpty == false {
            return nil
        }

        let name = stringValue(dictionary["name"]) ?? stringValue(dictionary["Name"])
        guard let name else {
            return nil
        }

        let history = historySamples(from: dictionary["history"])
        let latestDelay = history.compactMap(\.delay).last ?? intValue(dictionary["delay"])

        return MihomoProxyNode(
            id: name,
            name: name,
            type: stringValue(dictionary["type"]) ?? "Unknown",
            alive: boolValue(dictionary["alive"]),
            delay: latestDelay,
            udpSupported: boolValue(dictionary["udp"]),
            provider: stringValue(dictionary["provider"]) ?? stringValue(dictionary["providerName"]),
            icon: stringValue(dictionary["icon"]),
            history: history
        )
    }

    private nonisolated static func dictionaries(
        from object: Any,
        preferredKeys: [String]
    ) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        if let dictionary = object as? [String: Any] {
            for key in preferredKeys {
                if let nestedDictionary = dictionary[key] as? [String: Any] {
                    return Array(nestedDictionary.values.compactMap { $0 as? [String: Any] })
                }

                if let nestedArray = dictionary[key] as? [[String: Any]] {
                    return nestedArray
                }
            }

            return [dictionary]
        }

        return []
    }

    private nonisolated static func historySamples(from value: Any?) -> [MihomoLatencySample] {
        let items = value as? [[String: Any]] ?? []
        return items.map { item in
            MihomoLatencySample(
                timestamp: dateValue(item["time"]),
                delay: intValue(item["delay"])
            )
        }
    }

    private nonisolated static func jsonObject(from data: Data, path: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MihomoControllerError.transport(path: path, message: error.localizedDescription)
        }
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private nonisolated static func stringArrayValue(_ value: Any?) -> [String] {
        switch value {
        case let array as [String]:
            return array
        case let array as [Any]:
            return array.compactMap { stringValue($0) }
        default:
            return []
        }
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["1", "true", "yes", "on"].contains(string.lowercased())
        default:
            return nil
        }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let int64 as Int64:
            return Int(int64)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private nonisolated static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let int64 as Int64:
            return int64
        case let int as Int:
            return Int64(int)
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        case let int64 as Int64:
            return Double(int64)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private nonisolated static func dateValue(_ value: Any?) -> Date? {
        guard let raw = stringValue(value) else {
            return nil
        }

        if let date = ISO8601DateFormatter().date(from: raw) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXX"
        if let date = formatter.date(from: raw) {
            return date
        }

        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}
