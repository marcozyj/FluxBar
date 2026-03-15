import Foundation

actor SubscriptionStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSources() throws -> [SubscriptionSourceRecord] {
        let metadataURL = try metadataURL()
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode([SubscriptionSourceRecord].self, from: data)
    }

    func saveSources(_ sources: [SubscriptionSourceRecord]) throws {
        let metadataURL = try metadataURL()
        let data = try encoder.encode(sources)
        try data.write(to: metadataURL, options: .atomic)
    }

    func writePayload(_ data: Data, fileName: String, for sourceID: UUID) throws -> URL {
        let directoryURL = try sourceDirectory(for: sourceID)
        let payloadURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: payloadURL, options: .atomic)
        return payloadURL
    }

    func payloadURL(for source: SubscriptionSourceRecord) throws -> URL? {
        guard let storedFileName = source.storedFileName else {
            return nil
        }

        return try sourceDirectory(for: source.id).appendingPathComponent(storedFileName, isDirectory: false)
    }

    private func metadataURL() throws -> URL {
        try FluxBarStorageDirectories
            .subscriptionsRoot(fileManager: fileManager)
            .appendingPathComponent("index.json", isDirectory: false)
    }

    private func sourceDirectory(for sourceID: UUID) throws -> URL {
        let root = try FluxBarStorageDirectories.subscriptionsRoot(fileManager: fileManager)
        return try FluxBarStorageDirectories.ensureDirectory(
            at: root.appendingPathComponent(sourceID.uuidString, isDirectory: true),
            fileManager: fileManager
        )
    }
}
