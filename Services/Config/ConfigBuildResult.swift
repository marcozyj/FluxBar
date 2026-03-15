import Foundation

struct ConfigBuildResult: Sendable {
    let kernel: KernelType
    let outputURL: URL
    let generatedAt: Date
    let sourceIDs: [UUID]
    let sourceNames: [String]
    let externalController: String?
    let secret: String?
    let renderedConfiguration: String

    nonisolated init(
        kernel: KernelType,
        outputURL: URL,
        generatedAt: Date = Date(),
        sourceIDs: [UUID],
        sourceNames: [String],
        externalController: String?,
        secret: String?,
        renderedConfiguration: String
    ) {
        self.kernel = kernel
        self.outputURL = outputURL
        self.generatedAt = generatedAt
        self.sourceIDs = sourceIDs
        self.sourceNames = sourceNames
        self.externalController = externalController
        self.secret = secret
        self.renderedConfiguration = renderedConfiguration
    }
}
