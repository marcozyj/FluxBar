import Foundation

protocol KernelBinaryLocating: Sendable {
    nonisolated func binaryURL(for kernel: KernelType, preferredURL: URL?) throws -> URL
}

struct DefaultKernelBinaryLocator: KernelBinaryLocating {
    nonisolated init() {}

    nonisolated func binaryURL(for kernel: KernelType, preferredURL: URL?) throws -> URL {
        let fileManager = FileManager.default
        let searchPaths = candidatePaths(for: kernel, preferredURL: preferredURL)

        for path in searchPaths {
            if fileManager.isExecutableFile(atPath: path.path) {
                return path
            }

            if fileManager.fileExists(atPath: path.path),
               let preparedURL = prepareExecutableIfNeeded(from: path, kernel: kernel, fileManager: fileManager) {
                return preparedURL
            }
        }

        throw KernelError.binaryNotFound(kernel, searchedPaths: searchPaths)
    }

    nonisolated private func candidatePaths(for kernel: KernelType, preferredURL: URL?) -> [URL] {
        var urls: [URL] = []

        if let preferredURL {
            urls.append(preferredURL)
        }

        let appSupportKernels = try? FluxBarStorageDirectories.kernelsRoot(fileManager: FileManager.default)
        let bundleResources = Bundle.main.resourceURL
        let envDirectory = ProcessInfo.processInfo.environment["FLUXBAR_KERNELS_DIR"].map(URL.init(fileURLWithPath:))

        let baseDirectories = [
            envDirectory,
            appSupportKernels,
            bundleResources?.appendingPathComponent("kernels", isDirectory: true),
            bundleResources
        ].compactMap { $0 }

        for directory in baseDirectories {
            for candidate in kernel.executableCandidates {
                urls.append(directory.appendingPathComponent(kernel.rawValue, isDirectory: true).appendingPathComponent(candidate))
                urls.append(directory.appendingPathComponent(candidate))
            }
        }

        return unique(urls)
    }

    nonisolated private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.path).inserted
        }
    }

    nonisolated private func prepareExecutableIfNeeded(
        from sourceURL: URL,
        kernel: KernelType,
        fileManager: FileManager
    ) -> URL? {
        if makeExecutable(at: sourceURL, fileManager: fileManager) {
            return sourceURL
        }

        guard let kernelsRoot = try? FluxBarStorageDirectories.kernelsRoot(fileManager: fileManager) else {
            return nil
        }

        let destinationURL = kernelsRoot.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            if makeExecutable(at: destinationURL, fileManager: fileManager) {
                return destinationURL
            }
        } catch {
            return nil
        }

        return nil
    }

    nonisolated private func makeExecutable(at url: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return false
        }

        return fileManager.isExecutableFile(atPath: url.path)
    }
}
