import Foundation

struct InstalledKernelRecord: Codable, Sendable {
    let kernel: KernelType
    let version: String
    let channel: KernelUpdateChannel
    let installedAt: Date
    let binaryPath: String
    let sourceURL: URL?
    let digest: String?

    nonisolated init(
        kernel: KernelType,
        version: String,
        channel: KernelUpdateChannel,
        installedAt: Date = Date(),
        binaryPath: String,
        sourceURL: URL?,
        digest: String?
    ) {
        self.kernel = kernel
        self.version = version
        self.channel = channel
        self.installedAt = installedAt
        self.binaryPath = binaryPath
        self.sourceURL = sourceURL
        self.digest = digest
    }

    nonisolated var binaryURL: URL {
        URL(fileURLWithPath: binaryPath)
    }
}

actor InstalledKernelRegistryStore {
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

    func record(for kernel: KernelType) throws -> InstalledKernelRecord? {
        try loadRegistry()[kernel]
    }

    func upsert(_ record: InstalledKernelRecord) throws {
        var registry = try loadRegistry()
        registry[record.kernel] = record
        try saveRegistry(registry)
    }

    private func loadRegistry() throws -> [KernelType: InstalledKernelRecord] {
        let registryURL = try self.registryURL()
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: registryURL)
        return try decoder.decode([KernelType: InstalledKernelRecord].self, from: data)
    }

    private func saveRegistry(_ registry: [KernelType: InstalledKernelRecord]) throws {
        let registryURL = try self.registryURL()
        let data = try encoder.encode(registry)
        try data.write(to: registryURL, options: .atomic)
    }

    private func registryURL() throws -> URL {
        try FluxBarStorageDirectories
            .kernelsRoot(fileManager: fileManager)
            .appendingPathComponent("registry.json", isDirectory: false)
    }
}
