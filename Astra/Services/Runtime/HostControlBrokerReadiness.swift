import Foundation

enum HostControlBrokerReadiness {
    static let helperPath = (
        RuntimePathResolver.astraToolsPath as NSString
    ).appendingPathComponent("astra-host-control")

    static func isAvailable(
        expectedHelperPath: String = helperPath,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.isExecutableFile(atPath: expectedHelperPath)
            && fileManager.isWritableFile(atPath: "/tmp")
    }
}
