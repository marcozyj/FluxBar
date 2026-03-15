import Foundation

enum KernelVersionInspector {
    static func currentVersion(for kernel: KernelType) async -> String? {
        let registry = InstalledKernelRegistryStore()
        if let version = try? await registry.record(for: kernel)?.version {
            return version
        }

        guard let binaryURL = try? DefaultKernelBinaryLocator().binaryURL(for: kernel, preferredURL: nil) else {
            return nil
        }

        return detectVersion(for: binaryURL)
    }

    private static func detectVersion(for binaryURL: URL) -> String? {
        for arguments in [["-v"], ["version"], ["--version"]] {
            if let output = run(binaryURL: binaryURL, arguments: arguments),
               let version = extractVersion(from: output),
               version.isEmpty == false {
                return version
            }
        }

        return nil
    }

    private static func run(binaryURL: URL, arguments: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = binaryURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let stdoutText = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let merged = "\(stdoutText)\n\(stderrText)".trimmingCharacters(in: .whitespacesAndNewlines)
        return merged.isEmpty ? nil : merged
    }

    private static func extractVersion(from text: String) -> String? {
        let pattern = #"v?\d+(?:\.\d+){1,3}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = expression.firstMatch(in: text, range: range),
            let matchedRange = Range(match.range(at: 0), in: text)
        else {
            return nil
        }

        let version = String(text[matchedRange])
        return version.hasPrefix("v") ? version : "v\(version)"
    }
}
