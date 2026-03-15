import Foundation

struct KernelReleaseAsset: Codable, Sendable {
    let name: String
    let downloadURL: URL
    let digest: String?
    let size: Int64?
    let archiveFormat: KernelAssetArchiveFormat
    let executableName: String

    nonisolated init(
        name: String,
        downloadURL: URL,
        digest: String? = nil,
        size: Int64? = nil,
        archiveFormat: KernelAssetArchiveFormat,
        executableName: String
    ) {
        self.name = name
        self.downloadURL = downloadURL
        self.digest = digest
        self.size = size
        self.archiveFormat = archiveFormat
        self.executableName = executableName
    }
}

struct KernelReleaseManifest: Codable, Sendable {
    let kernel: KernelType
    let version: String
    let publishedAt: Date?
    let releaseNotesURL: URL?
    let channel: KernelUpdateChannel
    let asset: KernelReleaseAsset
    let sourceDescription: String

    nonisolated init(
        kernel: KernelType,
        version: String,
        publishedAt: Date?,
        releaseNotesURL: URL?,
        channel: KernelUpdateChannel,
        asset: KernelReleaseAsset,
        sourceDescription: String
    ) {
        self.kernel = kernel
        self.version = version
        self.publishedAt = publishedAt
        self.releaseNotesURL = releaseNotesURL
        self.channel = channel
        self.asset = asset
        self.sourceDescription = sourceDescription
    }
}

enum KernelUpdateCheckStatus: String, Sendable {
    case updateAvailable
    case upToDate
    case notInstalled
    case installedVersionUnknown
    case sourceUnavailable
}

struct KernelUpdateCheckResult: Sendable {
    let kernel: KernelType
    let status: KernelUpdateCheckStatus
    let installedVersion: String?
    let installedBinaryURL: URL?
    let latestRelease: KernelReleaseManifest?
    let message: String

    nonisolated init(
        kernel: KernelType,
        status: KernelUpdateCheckStatus,
        installedVersion: String?,
        installedBinaryURL: URL?,
        latestRelease: KernelReleaseManifest?,
        message: String
    ) {
        self.kernel = kernel
        self.status = status
        self.installedVersion = installedVersion
        self.installedBinaryURL = installedBinaryURL
        self.latestRelease = latestRelease
        self.message = message
    }
}
