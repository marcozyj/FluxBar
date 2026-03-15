import Foundation

struct MihomoControllerConfiguration: Sendable {
    let bindAddress: String
    let apiBaseURL: URL
    let secret: String?
    let preferLoopbackAccess: Bool

    nonisolated init(
        controllerAddress: String,
        secret: String?,
        scheme: String = "http",
        preferLoopbackAccess: Bool = true
    ) throws {
        let trimmed = controllerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw MihomoControllerError.invalidControllerAddress(controllerAddress)
        }

        let rawURLString = trimmed.contains("://") ? trimmed : "\(scheme)://\(trimmed)"
        guard
            let rawURL = URL(string: rawURLString),
            var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
            let host = components.host
        else {
            throw MihomoControllerError.invalidControllerAddress(controllerAddress)
        }

        self.bindAddress = trimmed
        self.secret = secret
        self.preferLoopbackAccess = preferLoopbackAccess

        if preferLoopbackAccess, Self.isWildcardHost(host) {
            components.host = "127.0.0.1"
        }

        guard let apiBaseURL = components.url else {
            throw MihomoControllerError.invalidControllerAddress(controllerAddress)
        }

        self.apiBaseURL = apiBaseURL
    }

    nonisolated init(
        apiBaseURL: URL,
        bindAddress: String? = nil,
        secret: String? = nil,
        preferLoopbackAccess: Bool = true
    ) {
        self.apiBaseURL = apiBaseURL
        self.bindAddress = bindAddress ?? apiBaseURL.host(percentEncoded: false) ?? apiBaseURL.absoluteString
        self.secret = secret
        self.preferLoopbackAccess = preferLoopbackAccess
    }

    private nonisolated static func isWildcardHost(_ host: String) -> Bool {
        switch host {
        case "0.0.0.0", "::", "[::]":
            return true
        default:
            return false
        }
    }
}
