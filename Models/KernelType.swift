import Foundation

enum KernelType: String, CaseIterable, Codable, Identifiable, Sendable {
    case mihomo
    case smart

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String { rawValue }

    nonisolated var executableCandidates: [String] {
        [
            rawValue,
            "\(rawValue)-darwin",
            "\(rawValue)-macos"
        ]
    }
}
