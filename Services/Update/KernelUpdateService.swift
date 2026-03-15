import CryptoKit
import Foundation

actor KernelUpdateService {
    static let shared = KernelUpdateService()

    private let fileManager: FileManager
    private let registryStore: InstalledKernelRegistryStore
    private let binaryLocator: any KernelBinaryLocating
    private let mihomoReleaseProvider: any KernelReleaseProviding
    private let smartReleaseProvider: any KernelReleaseProviding
    private let session: URLSession

    init(
        fileManager: FileManager = .default,
        registryStore: InstalledKernelRegistryStore = InstalledKernelRegistryStore(),
        binaryLocator: any KernelBinaryLocating = DefaultKernelBinaryLocator(),
        mihomoReleaseProvider: any KernelReleaseProviding = GitHubKernelReleaseProvider(),
        smartReleaseProvider: any KernelReleaseProviding = ManifestKernelReleaseProvider(),
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.registryStore = registryStore
        self.binaryLocator = binaryLocator
        self.mihomoReleaseProvider = mihomoReleaseProvider
        self.smartReleaseProvider = smartReleaseProvider
        self.session = session
    }

    func checkForUpdates(
        for kernel: KernelType,
        channel: KernelUpdateChannel = .stable
    ) async throws -> KernelUpdateCheckResult {
        let installedRecord = try? await registryStore.record(for: kernel)
        let installedBinaryURL = installedRecord?.binaryURL ?? (try? binaryLocator.binaryURL(for: kernel, preferredURL: nil))
        let latestRelease = try await latestRelease(for: kernel, channel: channel)

        guard let latestRelease else {
            return KernelUpdateCheckResult(
                kernel: kernel,
                status: .sourceUnavailable,
                installedVersion: installedRecord?.version,
                installedBinaryURL: installedBinaryURL,
                latestRelease: nil,
                message: "\(kernel.displayName) 未配置可用更新源"
            )
        }

        guard let installedRecord else {
            return KernelUpdateCheckResult(
                kernel: kernel,
                status: installedBinaryURL == nil ? .notInstalled : .installedVersionUnknown,
                installedVersion: nil,
                installedBinaryURL: installedBinaryURL,
                latestRelease: latestRelease,
                message: installedBinaryURL == nil
                    ? "检测到 \(latestRelease.version)，尚未安装 \(kernel.displayName)"
                    : "检测到 \(latestRelease.version)，当前安装版本未知"
            )
        }

        let comparison = compareVersions(installedRecord.version, latestRelease.version)
        let status: KernelUpdateCheckStatus = comparison == .orderedAscending ? .updateAvailable : .upToDate
        let message = status == .updateAvailable
            ? "发现新版本 \(latestRelease.version)"
            : "\(kernel.displayName) 已是最新版本"

        return KernelUpdateCheckResult(
            kernel: kernel,
            status: status,
            installedVersion: installedRecord.version,
            installedBinaryURL: installedRecord.binaryURL,
            latestRelease: latestRelease,
            message: message
        )
    }

    func installLatestUpdate(
        for kernel: KernelType,
        channel: KernelUpdateChannel = .stable
    ) async throws -> InstalledKernelRecord {
        guard let latestRelease = try await latestRelease(for: kernel, channel: channel) else {
            throw KernelUpdateError.releaseSourceUnavailable(kernel)
        }

        let artifact = try await downloadRelease(latestRelease)
        return try await installDownloadedArtifact(artifact, manifest: latestRelease)
    }

    func downloadRelease(_ manifest: KernelReleaseManifest) async throws -> URL {
        let stagingDirectory = try makeStagingDirectory(for: manifest)
        let archiveURL = stagingDirectory.appendingPathComponent(manifest.asset.name, isDirectory: false)
        let binaryURL = stagingDirectory.appendingPathComponent(manifest.asset.executableName, isDirectory: false)

        var request = URLRequest(url: manifest.asset.downloadURL)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw KernelUpdateError.downloadFailed(
                manifest.asset.downloadURL,
                underlying: "HTTP 状态异常"
            )
        }

        try data.write(to: archiveURL, options: .atomic)

        if let digest = manifest.asset.digest, digest.isEmpty == false {
            let actual = Self.sha256Hex(for: data)
            let expected = normalizeDigest(digest)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw KernelUpdateError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        switch manifest.asset.archiveFormat {
        case .raw:
            try fileManager.copyItem(at: archiveURL, to: binaryURL)
        case .gzip:
            try decompressGzip(from: archiveURL, to: binaryURL)
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        return binaryURL
    }

    func installDownloadedArtifact(
        _ binaryURL: URL,
        manifest: KernelReleaseManifest
    ) async throws -> InstalledKernelRecord {
        let destinationDirectory = try FluxBarStorageDirectories.kernelDirectory(for: manifest.kernel, fileManager: fileManager)
        let destinationURL = destinationDirectory.appendingPathComponent(manifest.kernel.rawValue, isDirectory: false)
        let backupURL = destinationDirectory.appendingPathComponent("\(manifest.kernel.rawValue).backup", isDirectory: false)

        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
            }

            try fileManager.copyItem(at: binaryURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path), fileManager.fileExists(atPath: destinationURL.path) == false {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }

            throw KernelUpdateError.installFailed(manifest.kernel, underlying: error.localizedDescription)
        }

        let installedDigest = try Self.sha256Hex(forContentsOf: destinationURL)
        let record = InstalledKernelRecord(
            kernel: manifest.kernel,
            version: manifest.version,
            channel: manifest.channel,
            binaryPath: destinationURL.path,
            sourceURL: manifest.asset.downloadURL,
            digest: installedDigest
        )

        try await registryStore.upsert(record)
        return record
    }

    private func latestRelease(
        for kernel: KernelType,
        channel: KernelUpdateChannel
    ) async throws -> KernelReleaseManifest? {
        switch kernel {
        case .mihomo:
            return try await mihomoReleaseProvider.latestRelease(
                for: kernel,
                channel: channel,
                platform: .current
            )
        case .smart:
            return try await smartReleaseProvider.latestRelease(
                for: kernel,
                channel: channel,
                platform: .current
            )
        }
    }

    private func makeStagingDirectory(for manifest: KernelReleaseManifest) throws -> URL {
        let root = try FluxBarStorageDirectories.updatesRoot(fileManager: fileManager)
        let kernelDirectory = root.appendingPathComponent(manifest.kernel.rawValue, isDirectory: true)
        let versionDirectory = kernelDirectory.appendingPathComponent(manifest.version, isDirectory: true)
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        return versionDirectory
    }

    private func normalizeDigest(_ digest: String) -> String {
        if digest.hasPrefix("sha256:") {
            return String(digest.dropFirst("sha256:".count))
        }
        return digest
    }

    private func decompressGzip(from sourceURL: URL, to destinationURL: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", sourceURL.path]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw KernelUpdateError.extractionFailed(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw KernelUpdateError.extractionFailed(message.isEmpty ? "gunzip 返回 \(process.terminationStatus)" : message)
        }

        try outputData.write(to: destinationURL, options: .atomic)
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = normalizedVersionParts(lhs)
        let rhsParts = normalizedVersionParts(rhs)
        let maxCount = max(lhsParts.count, rhsParts.count)

        for index in 0..<maxCount {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0

            if left < right {
                return .orderedAscending
            }

            if left > right {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    private func normalizedVersionParts(_ version: String) -> [Int] {
        version
            .lowercased()
            .replacingOccurrences(of: "v", with: "")
            .split { character in
                character.isNumber == false
            }
            .compactMap { Int($0) }
    }

    private nonisolated static func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sha256Hex(forContentsOf fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return sha256Hex(for: data)
    }
}
