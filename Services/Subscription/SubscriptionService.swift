import CryptoKit
import Foundation

actor SubscriptionService {
    static let shared = SubscriptionService()

    private let store: SubscriptionStore
    private let session: URLSession

    init(
        store: SubscriptionStore = SubscriptionStore(),
        session: URLSession = .shared
    ) {
        self.store = store
        self.session = session
    }

    func listSources() async throws -> [SubscriptionSourceRecord] {
        try await sortedSources()
    }

    func addRemoteSubscription(
        urlString: String,
        name: String? = nil,
        isEnabled: Bool = true
    ) async throws -> SubscriptionSourceRecord {
        let remoteURL = try Self.validatedRemoteURL(from: urlString)
        var sources = try await sortedSources()

        if sources.contains(where: { $0.remoteURL?.absoluteString.caseInsensitiveCompare(remoteURL.absoluteString) == .orderedSame }) {
            throw SubscriptionError.duplicateRemoteURL(remoteURL)
        }

        let record = SubscriptionSourceRecord(
            name: Self.nonEmpty(name?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Self.defaultName(for: remoteURL),
            kind: .remoteURL,
            remoteURL: remoteURL,
            isEnabled: isEnabled,
            order: sources.count
        )
        sources.append(record)
        try await persistOrderedSources(sources)
        return record
    }

    func importLocalConfiguration(
        from fileURL: URL,
        name: String? = nil,
        isEnabled: Bool = true
    ) async throws -> SubscriptionSourceRecord {
        var sources = try await sortedSources()
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let bookmark = try? fileURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let summary = SubscriptionContentInspector.inspect(data: data)
            let record = SubscriptionSourceRecord(
                name: Self.nonEmpty(name?.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? summary.suggestedName
                    ?? fileURL.deletingPathExtension().lastPathComponent,
                kind: .localConfig,
                localFilePath: fileURL.path,
                localFileBookmark: bookmark,
                isEnabled: isEnabled,
                order: sources.count,
                lastUpdatedAt: Date(),
                lastContentHash: Self.sha256Hex(for: data),
                contentSummary: summary
            )

            let storedFileName = Self.sanitizedFileName(
                preferredName: fileURL.lastPathComponent,
                defaultExtension: fileURL.pathExtension.isEmpty ? "yaml" : fileURL.pathExtension
            )
            _ = try await store.writePayload(data, fileName: storedFileName, for: record.id)

            var persisted = record
            persisted.storedFileName = storedFileName
            sources.append(persisted)
            try await persistOrderedSources(sources)
            return persisted
        } catch {
            throw SubscriptionError.importFailed(fileURL.path, underlying: error.localizedDescription)
        }
    }

    func updateSubscription(id: UUID) async throws -> SubscriptionUpdateResult {
        var sources = try await sortedSources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw SubscriptionError.sourceNotFound(id)
        }

        do {
            let result = try await refreshSource(at: index, in: &sources)
            try await persistOrderedSources(sources)
            return result
        } catch {
            sources[index].lastErrorMessage = error.localizedDescription
            try await persistOrderedSources(sources)
            throw error
        }
    }

    func updateAllSubscriptions() async -> [SubscriptionUpdateResult] {
        do {
            var sources = try await sortedSources()
            var results: [SubscriptionUpdateResult] = []

            for index in sources.indices {
                do {
                    let result = try await refreshSource(at: index, in: &sources)
                    results.append(result)
                } catch {
                    sources[index].lastErrorMessage = error.localizedDescription
                    results.append(
                        SubscriptionUpdateResult(
                            sourceID: sources[index].id,
                            sourceName: sources[index].name,
                            status: .failed,
                            summary: sources[index].contentSummary,
                            message: error.localizedDescription
                        )
                    )
                }
            }

            try await persistOrderedSources(sources)
            return results
        } catch {
            return []
        }
    }

    func payloadURL(for sourceID: UUID) async throws -> URL {
        let sources = try await sortedSources()
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            throw SubscriptionError.sourceNotFound(sourceID)
        }

        guard let payloadURL = try await store.payloadURL(for: source) else {
            throw SubscriptionError.storageFailure("订阅 \(source.name) 尚未生成本地内容文件")
        }

        return payloadURL
    }

    private func refreshSource(
        at index: Int,
        in sources: inout [SubscriptionSourceRecord]
    ) async throws -> SubscriptionUpdateResult {
        switch sources[index].kind {
        case .remoteURL:
            return try await refreshRemoteSource(at: index, in: &sources)
        case .localConfig:
            return try await refreshLocalSource(at: index, in: &sources)
        }
    }

    private func refreshRemoteSource(
        at index: Int,
        in sources: inout [SubscriptionSourceRecord]
    ) async throws -> SubscriptionUpdateResult {
        var source = sources[index]
        guard let remoteURL = source.remoteURL else {
            throw SubscriptionError.missingRemoteURL(source.id)
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/plain, application/yaml, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        if let etag = source.lastResponseETag, etag.isEmpty == false {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = source.lastResponseLastModified, lastModified.isEmpty == false {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.updateFailed(source.id, underlying: "未收到 HTTP 响应")
        }

        if httpResponse.statusCode == 304 {
            source.lastErrorMessage = nil
            sources[index] = source
            return SubscriptionUpdateResult(
                sourceID: source.id,
                sourceName: source.name,
                status: .unchanged,
                summary: source.contentSummary,
                message: "订阅未变化"
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SubscriptionError.invalidResponse(remoteURL, statusCode: httpResponse.statusCode)
        }

        let summary = SubscriptionContentInspector.inspect(data: data)
        let contentHash = Self.sha256Hex(for: data)
        let isChanged = source.lastContentHash != contentHash || source.storedFileName == nil

        let preferredFileName = Self.sanitizedFileName(
            preferredName: remoteURL.lastPathComponent.isEmpty ? source.name : remoteURL.lastPathComponent,
            defaultExtension: remoteURL.pathExtension.isEmpty ? "yaml" : remoteURL.pathExtension
        )

        if isChanged {
            _ = try await store.writePayload(data, fileName: preferredFileName, for: source.id)
            source.storedFileName = preferredFileName
        }

        if source.name.isEmpty || source.name == Self.defaultName(for: remoteURL) {
            source.name = summary.suggestedName ?? Self.defaultName(for: remoteURL)
        }

        source.lastUpdatedAt = Date()
        source.lastContentHash = contentHash
        source.lastResponseETag = httpResponse.value(forHTTPHeaderField: "ETag")
        source.lastResponseLastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
        source.lastErrorMessage = nil
        source.contentSummary = summary
        sources[index] = source

        return SubscriptionUpdateResult(
            sourceID: source.id,
            sourceName: source.name,
            status: isChanged ? .updated : .unchanged,
            summary: summary,
            message: isChanged ? "订阅已更新" : "订阅内容未变化"
        )
    }

    private func refreshLocalSource(
        at index: Int,
        in sources: inout [SubscriptionSourceRecord]
    ) async throws -> SubscriptionUpdateResult {
        var source = sources[index]
        let localFileURL = try Self.resolveLocalFileURL(for: source)
        let accessGranted = localFileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                localFileURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw SubscriptionError.localFileUnavailable(localFileURL.path)
        }

        let data = try Data(contentsOf: localFileURL)
        let summary = SubscriptionContentInspector.inspect(data: data)
        let contentHash = Self.sha256Hex(for: data)
        let isChanged = source.lastContentHash != contentHash || source.storedFileName == nil

        if isChanged {
            let storedFileName = Self.sanitizedFileName(
                preferredName: localFileURL.lastPathComponent,
                defaultExtension: localFileURL.pathExtension.isEmpty ? "yaml" : localFileURL.pathExtension
            )
            _ = try await store.writePayload(data, fileName: storedFileName, for: source.id)
            source.storedFileName = storedFileName
        }

        source.lastUpdatedAt = Date()
        source.lastContentHash = contentHash
        source.lastErrorMessage = nil
        source.localFilePath = localFileURL.path
        source.contentSummary = summary
        sources[index] = source

        return SubscriptionUpdateResult(
            sourceID: source.id,
            sourceName: source.name,
            status: isChanged ? .updated : .unchanged,
            summary: summary,
            message: isChanged ? "本地配置已重新导入" : "本地配置未变化"
        )
    }

    private func sortedSources() async throws -> [SubscriptionSourceRecord] {
        try await store.loadSources()
            .sorted { lhs, rhs in
                if lhs.order == rhs.order {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.order < rhs.order
            }
    }

    private func persistOrderedSources(_ sources: [SubscriptionSourceRecord]) async throws {
        let normalized = sources.enumerated().map { offset, item in
            var copy = item
            copy.order = offset
            return copy
        }
        try await store.saveSources(normalized)
    }

    private nonisolated static func validatedRemoteURL(from urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let remoteURL = URL(string: trimmed),
            let scheme = remoteURL.scheme?.lowercased(),
            remoteURL.host?.isEmpty == false
        else {
            throw SubscriptionError.invalidRemoteURL(urlString)
        }

        guard ["http", "https"].contains(scheme) else {
            throw SubscriptionError.unsupportedRemoteScheme(scheme)
        }

        return remoteURL
    }

    private nonisolated static func defaultName(for remoteURL: URL) -> String {
        if remoteURL.lastPathComponent.isEmpty == false {
            return remoteURL.deletingPathExtension().lastPathComponent
        }

        return remoteURL.host() ?? remoteURL.absoluteString
    }

    private nonisolated static func resolveLocalFileURL(for source: SubscriptionSourceRecord) throws -> URL {
        var isStale = false

        if let bookmark = source.localFileBookmark,
           let bookmarkURL = try? URL(
               resolvingBookmarkData: bookmark,
               options: [.withSecurityScope],
               relativeTo: nil,
               bookmarkDataIsStale: &isStale
           ) {
            return bookmarkURL
        }

        if let localFilePath = source.localFilePath, localFilePath.isEmpty == false {
            return URL(fileURLWithPath: localFilePath)
        }

        throw SubscriptionError.localFileUnavailable(source.localFilePath ?? source.name)
    }

    private nonisolated static func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sanitizedFileName(preferredName: String, defaultExtension: String) -> String {
        let fileExtension = Self.nonEmpty(defaultExtension.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "yaml"
        let basename = URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = basename.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let finalBasename = Self.nonEmpty(sanitized) ?? "subscription"
        return "\(finalBasename).\(fileExtension)"
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.isEmpty == false else {
            return nil
        }
        return value
    }
}
