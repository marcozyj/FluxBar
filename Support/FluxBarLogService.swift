import Foundation

actor FluxBarLogService {
    static let shared = FluxBarLogService()

    private let maxBufferedEntries = 600
    private let maxPersistedFileBytes = 1_024 * 1_024
    private let trimmedPersistedEntries = 1_200
    private let maxMessageLength = 4_096
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var hasLoadedPersistedEntries = false
    private var entries: [FluxLogEntry] = []

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

    func clear() async {
        entries.removeAll()
        hasLoadedPersistedEntries = true

        guard let logFileURL = try? logFileURL() else {
            return
        }

        try? Data().write(to: logFileURL, options: .atomic)
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
    }

    private func persist(entries newEntries: [FluxLogEntry]) {
        guard let logFileURL = try? logFileURL() else {
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

        trimPersistedFileIfNeeded()
    }

    private func loadPersistedEntries() throws -> [FluxLogEntry] {
        let logFileURL = try logFileURL()

        guard fileManager.fileExists(atPath: logFileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: logFileURL)
        guard data.isEmpty == false, let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let parsedEntries = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> FluxLogEntry? in
                guard let data = line.data(using: .utf8) else {
                    return nil
                }

                return try? decoder.decode(FluxLogEntry.self, from: data)
            }

        if parsedEntries.count > maxBufferedEntries {
            return Array(parsedEntries.suffix(maxBufferedEntries))
        }

        return parsedEntries
    }

    private func logFileURL() throws -> URL {
        try FluxBarStorageDirectories.logsRoot(fileManager: fileManager)
            .appendingPathComponent("fluxbar-log.jsonl", isDirectory: false)
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

    private func trimPersistedFileIfNeeded() {
        guard
            let logFileURL = try? logFileURL(),
            let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.intValue > maxPersistedFileBytes,
            let data = try? Data(contentsOf: logFileURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        let lines = text.split(whereSeparator: \.isNewline)
        let tail = lines.suffix(trimmedPersistedEntries)
        let trimmedText = tail.joined(separator: "\n")
        let output = trimmedText.isEmpty ? "" : "\(trimmedText)\n"

        try? Data(output.utf8).write(to: logFileURL, options: .atomic)
    }
}
