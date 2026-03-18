import Foundation

enum FluxBarDefaultConfigurationLocator {
    nonisolated static func locate(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let explicitCandidates = [
            environment["FLUXBAR_DEFAULT_CONFIG"],
            environment["CLASHBAR_CONFIG_PATH"]
        ]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }

        let configCandidates = seededConfigCandidates(fileManager: fileManager)
        let desktopDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let defaultCandidates = [
            desktopDirectory.appendingPathComponent("ClashBar.yaml", isDirectory: false),
            desktopDirectory.appendingPathComponent("FluxBar.yaml", isDirectory: false)
        ]

        let allCandidates = explicitCandidates + configCandidates + defaultCandidates
        return allCandidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    nonisolated private static func seededConfigCandidates(fileManager: FileManager) -> [URL] {
        guard let configsRoot = try? FluxBarStorageDirectories.configsRoot(fileManager: fileManager) else {
            return []
        }

        FluxBarConfigCleanupService.pruneManagedYAMLFiles(fileManager: fileManager)

        let sourceCandidates = unique(
            bundledConfigCandidates(fileManager: fileManager) +
            workspaceConfigCandidates(fileManager: fileManager)
        )

        if let sourceURL = sourceCandidates.first {
            let destinationURL = configsRoot.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)

            if fileManager.fileExists(atPath: destinationURL.path) == false {
                try? fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        }

        return configCandidates(in: configsRoot, fileManager: fileManager)
    }

    nonisolated private static func bundledConfigCandidates(fileManager: FileManager) -> [URL] {
        guard let resourceURL = Bundle.main.resourceURL else {
            return []
        }

        return unique(
            configCandidates(in: resourceURL.appendingPathComponent("config", isDirectory: true), fileManager: fileManager) +
            configCandidates(in: resourceURL, fileManager: fileManager)
        )
    }

    nonisolated private static func workspaceConfigCandidates(fileManager: FileManager) -> [URL] {
        let workspaceResourcesURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
        return unique(
            configCandidates(in: workspaceResourcesURL.appendingPathComponent("config", isDirectory: true), fileManager: fileManager) +
            configCandidates(in: workspaceResourcesURL, fileManager: fileManager)
        )
    }

    nonisolated private static func configCandidates(in directoryURL: URL, fileManager: FileManager) -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let preferredNames = ["ClashBar.yaml", "FluxBar.yaml", "config.yaml", "config.yml"]
        let preferredCandidates = preferredNames.map { directoryURL.appendingPathComponent($0, isDirectory: false) }

        let enumeratedCandidates: [URL]
        if let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            enumeratedCandidates = contents
                .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            enumeratedCandidates = []
        }

        return unique(preferredCandidates + enumeratedCandidates).filter { fileManager.fileExists(atPath: $0.path) }
    }

    nonisolated private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
