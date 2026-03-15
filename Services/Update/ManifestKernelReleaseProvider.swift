import Foundation

struct ManifestKernelReleaseProvider: KernelReleaseProviding {
    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func latestRelease(
        for kernel: KernelType,
        channel: KernelUpdateChannel,
        platform: KernelTargetPlatform
    ) async throws -> KernelReleaseManifest? {
        guard kernel == .smart else {
            return nil
        }

        guard let manifestLocation = manifestLocation(for: kernel) else {
            return nil
        }

        let data: Data
        switch manifestLocation {
        case .remote(let url):
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (remoteData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw KernelUpdateError.releaseSourceUnavailable(kernel)
            }
            data = remoteData
        case .localFile(let url):
            data = try Data(contentsOf: url)
        }

        return try parseManifest(
            for: kernel,
            data: data,
            channel: channel,
            platform: platform,
            sourceDescription: manifestLocation.description
        )
    }

    private nonisolated func manifestLocation(for kernel: KernelType) -> ManifestLocation? {
        let environment = ProcessInfo.processInfo.environment
        let uppercasedKernel = kernel.rawValue.uppercased()

        if let urlString = environment["FLUXBAR_\(uppercasedKernel)_RELEASE_MANIFEST_URL"],
           let url = URL(string: urlString) {
            return .remote(url)
        }

        if let path = environment["FLUXBAR_\(uppercasedKernel)_RELEASE_MANIFEST_PATH"], path.isEmpty == false {
            return .localFile(URL(fileURLWithPath: path))
        }

        return nil
    }

    private nonisolated func parseManifest(
        for kernel: KernelType,
        data: Data,
        channel: KernelUpdateChannel,
        platform: KernelTargetPlatform,
        sourceDescription: String
    ) throws -> KernelReleaseManifest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KernelUpdateError.invalidManifest("根节点必须是对象")
        }

        guard let version = object["version"] as? String else {
            throw KernelUpdateError.invalidManifest("缺少 version")
        }

        let manifestChannel = (object["channel"] as? String).flatMap(KernelUpdateChannel.init(rawValue:))
        if let manifestChannel, manifestChannel != channel {
            throw KernelUpdateError.releaseSourceUnavailable(kernel)
        }

        let assetsObject = object["assets"] ?? object["asset"]
        let asset = try selectAsset(from: assetsObject, platform: platform, kernel: kernel)

        let publishedAt: Date?
        if let publishedAtString = object["publishedAt"] as? String {
            publishedAt = ISO8601DateFormatter().date(from: publishedAtString)
        } else {
            publishedAt = nil
        }

        let releaseNotesURL = (object["releaseNotesURL"] as? String).flatMap(URL.init(string:))

        return KernelReleaseManifest(
            kernel: kernel,
            version: version,
            publishedAt: publishedAt,
            releaseNotesURL: releaseNotesURL,
            channel: manifestChannel ?? channel,
            asset: asset,
            sourceDescription: sourceDescription
        )
    }

    private nonisolated func selectAsset(
        from assetsObject: Any?,
        platform: KernelTargetPlatform,
        kernel: KernelType
    ) throws -> KernelReleaseAsset {
        let assetDictionaries: [[String: Any]]

        if let dictionary = assetsObject as? [String: Any] {
            assetDictionaries = [dictionary]
        } else if let array = assetsObject as? [[String: Any]] {
            assetDictionaries = array
        } else {
            throw KernelUpdateError.invalidManifest("缺少 assets")
        }

        for dictionary in assetDictionaries {
            let os = dictionary["os"] as? String ?? dictionary["platform"] as? String ?? "darwin"
            let arch = dictionary["arch"] as? String ?? dictionary["architecture"] as? String ?? platform.architecture.rawValue

            guard os == platform.operatingSystem, arch == platform.architecture.rawValue else {
                continue
            }

            guard
                let name = dictionary["name"] as? String,
                let downloadURLString = dictionary["downloadURL"] as? String ?? dictionary["url"] as? String,
                let downloadURL = URL(string: downloadURLString)
            else {
                throw KernelUpdateError.invalidManifest("asset 缺少 name/url")
            }

            let archiveFormat = (dictionary["archiveFormat"] as? String)
                .flatMap(KernelAssetArchiveFormat.init(rawValue:))
                ?? (name.hasSuffix(".gz") ? .gzip : .raw)
            let executableName = (dictionary["executableName"] as? String) ?? kernel.rawValue
            let digest = dictionary["digest"] as? String ?? dictionary["sha256"] as? String
            let size = (dictionary["size"] as? NSNumber)?.int64Value

            return KernelReleaseAsset(
                name: name,
                downloadURL: downloadURL,
                digest: digest,
                size: size,
                archiveFormat: archiveFormat,
                executableName: executableName
            )
        }

        throw KernelUpdateError.noCompatibleAsset(kernel, platform: "\(platform.operatingSystem)-\(platform.architecture.rawValue)")
    }
}

private enum ManifestLocation {
    case remote(URL)
    case localFile(URL)

    nonisolated var description: String {
        switch self {
        case .remote(let url):
            return "Manifest / \(url.absoluteString)"
        case .localFile(let url):
            return "Manifest / \(url.path)"
        }
    }
}
