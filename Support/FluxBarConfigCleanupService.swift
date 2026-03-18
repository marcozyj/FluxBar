import Foundation

enum FluxBarConfigCleanupService {
    nonisolated static func pruneManagedYAMLFiles(
        except preservedURLs: [URL] = [],
        fileManager: FileManager = .default
    ) {
        guard let configsRoot = try? FluxBarStorageDirectories.configsRoot(fileManager: fileManager) else {
            return
        }

        let preservedNames = Set(preservedURLs.map { $0.lastPathComponent.lowercased() })
        guard let contents = try? fileManager.contentsOfDirectory(
            at: configsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents {
            let name = url.lastPathComponent.lowercased()
            guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else {
                continue
            }

            guard preservedNames.contains(name) == false else {
                continue
            }

            guard isManagedGeneratedYAMLFileName(name) else {
                continue
            }

            try? fileManager.removeItem(at: url)
        }
    }

    nonisolated static func isManagedGeneratedYAMLFileName(_ lowerName: String) -> Bool {
        if lowerName == "fluxbar-tun-repro.yaml" {
            return true
        }

        if lowerName.hasPrefix("fluxbar-regression-"), lowerName.hasSuffix(".yaml") || lowerName.hasSuffix(".yml") {
            return true
        }

        if lowerName.hasPrefix("fluxbar-"), lowerName.contains("-runtime."), lowerName.hasSuffix(".yaml") || lowerName.hasSuffix(".yml") {
            return true
        }

        return false
    }
}
