import Foundation

struct KernelStartRequest: Sendable {
    let kernel: KernelType
    var binaryURL: URL?
    var configurationURL: URL?
    var workingDirectoryURL: URL?
    var arguments: [String]
    var environment: [String: String]
    var controllerAddress: String?
    var secret: String?

    init(
        kernel: KernelType,
        binaryURL: URL? = nil,
        configurationURL: URL? = nil,
        workingDirectoryURL: URL? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        controllerAddress: String? = nil,
        secret: String? = nil
    ) {
        self.kernel = kernel
        self.binaryURL = binaryURL
        self.configurationURL = configurationURL
        self.workingDirectoryURL = workingDirectoryURL
        self.arguments = arguments
        self.environment = environment
        self.controllerAddress = controllerAddress
        self.secret = secret
    }
}
