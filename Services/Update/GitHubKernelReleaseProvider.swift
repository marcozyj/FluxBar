import Foundation

struct GitHubKernelReleaseProvider: KernelReleaseProviding {
    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func latestRelease(
        for kernel: KernelType,
        channel: KernelUpdateChannel,
        platform: KernelTargetPlatform
    ) async throws -> KernelReleaseManifest? {
        guard kernel == .mihomo else {
            return nil
        }

        let endpoint = endpointURL(for: channel)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FluxBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw KernelUpdateError.releaseSourceUnavailable(kernel)
        }

        let releases = try parseReleases(from: data, channel: channel)
        guard let release = releases.first else {
            throw KernelUpdateError.releaseSourceUnavailable(kernel)
        }

        guard let asset = selectMihomoAsset(from: release.assets, platform: platform) else {
            throw KernelUpdateError.noCompatibleAsset(kernel, platform: "\(platform.operatingSystem)-\(platform.architecture.rawValue)")
        }

        return KernelReleaseManifest(
            kernel: kernel,
            version: release.version,
            publishedAt: release.publishedAt,
            releaseNotesURL: release.releaseNotesURL,
            channel: channel,
            asset: asset,
            sourceDescription: "GitHub Releases / MetaCubeX/mihomo"
        )
    }

    private nonisolated func endpointURL(for channel: KernelUpdateChannel) -> URL {
        switch channel {
        case .stable:
            URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!
        case .prerelease:
            URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases?per_page=10")!
        }
    }

    private nonisolated func parseReleases(
        from data: Data,
        channel: KernelUpdateChannel
    ) throws -> [GitHubRelease] {
        let object = try JSONSerialization.jsonObject(with: data)

        if let dictionary = object as? [String: Any] {
            if let release = GitHubRelease(dictionary: dictionary) {
                return [release]
            }
            throw KernelUpdateError.invalidReleasePayload(.mihomo)
        }

        guard let array = object as? [[String: Any]] else {
            throw KernelUpdateError.invalidReleasePayload(.mihomo)
        }

        return array
            .compactMap(GitHubRelease.init(dictionary:))
            .filter { release in
                switch channel {
                case .stable:
                    return release.isPrerelease == false
                case .prerelease:
                    return true
                }
            }
    }

    private nonisolated func selectMihomoAsset(
        from assets: [GitHubReleaseAsset],
        platform: KernelTargetPlatform
    ) -> KernelReleaseAsset? {
        let candidates = assets.filter { asset in
            asset.name.hasSuffix(".gz")
        }

        let orderedMatchers: [String]
        switch platform.architecture {
        case .amd64:
            orderedMatchers = [
                "mihomo-darwin-amd64-v1-",
                "mihomo-darwin-amd64-compatible-",
                "mihomo-darwin-amd64-"
            ]
        case .arm64:
            orderedMatchers = [
                "mihomo-darwin-arm64-"
            ]
        }

        for matcher in orderedMatchers {
            if let asset = candidates.first(where: { asset in
                asset.name.contains(matcher)
                    && asset.name.contains("go120") == false
                    && asset.name.contains("go122") == false
                    && asset.name.contains("go124") == false
            }) {
                return asset.kernelReleaseAsset(executableName: "mihomo")
            }
        }

        return candidates.first?.kernelReleaseAsset(executableName: "mihomo")
    }
}

private struct GitHubRelease {
    let version: String
    let publishedAt: Date?
    let releaseNotesURL: URL?
    let isPrerelease: Bool
    let assets: [GitHubReleaseAsset]

    nonisolated init?(dictionary: [String: Any]) {
        guard let version = dictionary["tag_name"] as? String else {
            return nil
        }

        self.version = version
        self.isPrerelease = dictionary["prerelease"] as? Bool ?? false
        self.releaseNotesURL = (dictionary["html_url"] as? String).flatMap(URL.init(string:))

        if let publishedAtString = dictionary["published_at"] as? String {
            self.publishedAt = ISO8601DateFormatter().date(from: publishedAtString)
        } else {
            self.publishedAt = nil
        }

        let assets = (dictionary["assets"] as? [[String: Any]] ?? [])
            .compactMap(GitHubReleaseAsset.init(dictionary:))
        self.assets = assets
    }
}

private struct GitHubReleaseAsset {
    let name: String
    let downloadURL: URL
    let digest: String?
    let size: Int64?

    nonisolated init?(dictionary: [String: Any]) {
        guard
            let name = dictionary["name"] as? String,
            let downloadURLString = dictionary["browser_download_url"] as? String,
            let downloadURL = URL(string: downloadURLString)
        else {
            return nil
        }

        self.name = name
        self.downloadURL = downloadURL
        self.digest = dictionary["digest"] as? String
        self.size = (dictionary["size"] as? NSNumber)?.int64Value
    }

    nonisolated func kernelReleaseAsset(executableName: String) -> KernelReleaseAsset {
        KernelReleaseAsset(
            name: name,
            downloadURL: downloadURL,
            digest: digest,
            size: size,
            archiveFormat: name.hasSuffix(".gz") ? .gzip : .raw,
            executableName: executableName
        )
    }
}
