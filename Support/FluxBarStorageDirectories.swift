import Foundation

enum FluxBarStorageDirectories {
    nonisolated static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return try ensureDirectory(
            at: baseURL.appendingPathComponent("FluxBar", isDirectory: true),
            fileManager: fileManager
        )
    }

    nonisolated static func subscriptionsRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("Subscriptions", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func kernelsRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("kernels", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func kernelDirectory(for kernel: KernelType, fileManager: FileManager = .default) throws -> URL {
        let root = try kernelsRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent(kernel.rawValue, isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func configsRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("Configs", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func stateRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("State", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func updatesRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("Updates", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func tunnelRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("Tunnel", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func logsRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        return try ensureDirectory(at: root.appendingPathComponent("Logs", isDirectory: true), fileManager: fileManager)
    }

    nonisolated static func ensureDirectory(at directoryURL: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
