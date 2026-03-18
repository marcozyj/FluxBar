import Foundation

actor FluxBarLogService {
    static let shared = FluxBarLogService()

    private struct LogSubscriber {
        let limit: Int
        let continuation: AsyncStream<[FluxLogEntry]>.Continuation
    }

    private let maxBufferedEntries = 1_000
    private let maxPersistedFileBytes = 1_024 * 1_024
    private let maxPersistedFileCount = 5
    private let maxMessageLength = 4_096
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var hasLoadedPersistedEntries = false
    private var entries: [FluxLogEntry] = []
    private var subscribers: [UUID: LogSubscriber] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func recentEntries(limit: Int? = nil) async -> [FluxLogEntry] {
        try? bootstrapIfNeeded()

        guard let limit else {
            return entries.reversed()
        }

        return Array(entries.suffix(limit).reversed())
    }

    func record(source: FluxLogSource, level: FluxLogLevel, message: String) async {
        try? bootstrapIfNeeded()
        let entry = FluxLogEntry(source: source, level: level, message: normalizedMessage(message))
        guard shouldPersist(entry) else {
            return
        }

        appendEntries([entry])
    }

    func recordKernelOutput(_ lines: [String], kernel: KernelType) async {
        guard lines.isEmpty == false else {
            return
        }

        try? bootstrapIfNeeded()

        let source: FluxLogSource = kernel == .mihomo ? .mihomo : .smart
        let mappedEntries = lines.map { line in
            FluxLogEntry(
                source: source,
                level: FluxLogLevel.infer(from: line),
                message: normalizedMessage(line)
            )
        }
            .filter(shouldPersist)
        appendEntries(mappedEntries)
    }

    func recordControllerLog(_ entry: MihomoLogEntry) async {
        try? bootstrapIfNeeded()

        let mappedEntry = FluxLogEntry(
            source: .mihomo,
            level: fluxLevel(from: entry.level),
            message: normalizedMessage(entry.payload)
        )

        guard shouldPersist(mappedEntry) else {
            return
        }

        appendEntries([mappedEntry])
    }

    func recordControllerLogs(_ controllerEntries: [MihomoLogEntry]) async {
        guard controllerEntries.isEmpty == false else {
            return
        }

        try? bootstrapIfNeeded()

        let mappedEntries = controllerEntries.map { entry in
            FluxLogEntry(
                source: .mihomo,
                level: fluxLevel(from: entry.level),
                message: normalizedMessage(entry.payload)
            )
        }
            .filter(shouldPersist)
        appendEntries(mappedEntries)
    }

    func stream(limit: Int = 400) async -> AsyncStream<[FluxLogEntry]> {
        try? bootstrapIfNeeded()
        let normalizedLimit = max(1, limit)

        return AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = LogSubscriber(
                limit: normalizedLimit,
                continuation: continuation
            )

            continuation.yield(snapshotEntries(limit: normalizedLimit))
            continuation.onTermination = { _ in
                Task {
                    await self.removeSubscriber(id)
                }
            }
        }
    }

    func clear() async {
        entries.removeAll()
        hasLoadedPersistedEntries = true

        for url in persistedLogFileURLsInOrder() {
            try? fileManager.removeItem(at: url)
        }

        publishToSubscribers()
    }

    private func bootstrapIfNeeded() throws {
        guard hasLoadedPersistedEntries == false else {
            return
        }

        entries = try loadPersistedEntries()
        hasLoadedPersistedEntries = true
    }

    private func appendEntries(_ newEntries: [FluxLogEntry]) {
        guard newEntries.isEmpty == false else {
            return
        }

        entries.append(contentsOf: newEntries)

        if entries.count > maxBufferedEntries {
            entries.removeFirst(entries.count - maxBufferedEntries)
        }

        persist(entries: newEntries)
        publishToSubscribers()
    }

    private func persist(entries newEntries: [FluxLogEntry]) {
        guard let logFileURL = try? currentLogFileURL() else {
            return
        }

        if fileManager.fileExists(atPath: logFileURL.path) == false {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        guard let fileHandle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }

        defer {
            try? fileHandle.close()
        }

        do {
            try fileHandle.seekToEnd()

            for entry in newEntries {
                let data = try encoder.encode(entry)
                fileHandle.write(data)
                fileHandle.write(Data([0x0A]))
            }
        } catch {
            return
        }

        rotatePersistedFilesIfNeeded()
    }

    private func loadPersistedEntries() throws -> [FluxLogEntry] {
        var parsedEntries: [FluxLogEntry] = []
        for url in persistedLogFileURLsInOrder() {
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }

            let data = try Data(contentsOf: url)
            guard data.isEmpty == false, let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let lines = text
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> FluxLogEntry? in
                    guard let data = line.data(using: .utf8) else {
                        return nil
                    }
                    return try? decoder.decode(FluxLogEntry.self, from: data)
                }
            parsedEntries.append(contentsOf: lines)
        }

        if parsedEntries.count > maxBufferedEntries {
            return Array(parsedEntries.suffix(maxBufferedEntries))
        }

        return parsedEntries
    }

    private func currentLogFileURL() throws -> URL {
        try FluxBarStorageDirectories.logsRoot(fileManager: fileManager)
            .appendingPathComponent("fluxbar-log.jsonl", isDirectory: false)
    }

    private func archivedLogFileURL(index: Int) throws -> URL {
        try FluxBarStorageDirectories.logsRoot(fileManager: fileManager)
            .appendingPathComponent("fluxbar-log.\(index).jsonl", isDirectory: false)
    }

    private func persistedLogFileURLsInOrder() -> [URL] {
        var urls: [URL] = []
        if maxPersistedFileCount > 1 {
            for index in stride(from: maxPersistedFileCount - 1, through: 1, by: -1) {
                if let url = try? archivedLogFileURL(index: index) {
                    urls.append(url)
                }
            }
        }

        if let currentURL = try? currentLogFileURL() {
            urls.append(currentURL)
        }

        return urls
    }

    private func normalizedMessage(_ message: String) -> String {
        guard message.count > maxMessageLength else {
            return message
        }

        let prefix = message.prefix(maxMessageLength)
        return "\(prefix)… [truncated]"
    }

    private func shouldPersist(_ entry: FluxLogEntry) -> Bool {
        let lowercased = entry.message.lowercased()

        if entry.source == .app {
            let ignoredFragments = [
                "已打开日志面板",
                "用户从设置页打开日志面板",
                "已同步内核运行状态"
            ]
            if ignoredFragments.contains(where: { lowercased.contains($0.lowercased()) }) {
                return false
            }
        }

        if (entry.source == .mihomo || entry.source == .smart), entry.level == .debug {
            return false
        }

        return true
    }

    private func rotatePersistedFilesIfNeeded() {
        guard
            let currentURL = try? currentLogFileURL(),
            let attributes = try? fileManager.attributesOfItem(atPath: currentURL.path),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.intValue > maxPersistedFileBytes
        else {
            return
        }

        let oldestIndex = maxPersistedFileCount - 1
        if oldestIndex >= 1, let oldestURL = try? archivedLogFileURL(index: oldestIndex) {
            try? fileManager.removeItem(at: oldestURL)
        }

        if maxPersistedFileCount > 2 {
            for index in stride(from: maxPersistedFileCount - 2, through: 1, by: -1) {
                guard
                    let sourceURL = try? archivedLogFileURL(index: index),
                    fileManager.fileExists(atPath: sourceURL.path),
                    let destinationURL = try? archivedLogFileURL(index: index + 1)
                else {
                    continue
                }

                try? fileManager.removeItem(at: destinationURL)
                try? fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        if let firstArchiveURL = try? archivedLogFileURL(index: 1) {
            try? fileManager.removeItem(at: firstArchiveURL)
            try? fileManager.moveItem(at: currentURL, to: firstArchiveURL)
            fileManager.createFile(atPath: currentURL.path, contents: nil)
        }
    }

    private func fluxLevel(from level: MihomoLogLevel) -> FluxLogLevel {
        switch level {
        case .debug:
            return .debug
        case .info, .unknown:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    private func snapshotEntries(limit: Int) -> [FluxLogEntry] {
        Array(entries.suffix(limit).reversed())
    }

    private func publishToSubscribers() {
        guard subscribers.isEmpty == false else {
            return
        }

        for (_, subscriber) in subscribers {
            subscriber.continuation.yield(snapshotEntries(limit: subscriber.limit))
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
