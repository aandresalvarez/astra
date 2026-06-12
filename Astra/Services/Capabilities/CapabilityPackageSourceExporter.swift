import Foundation
import ASTRACore

struct CapabilityPackageSourceExporter {
    enum ExportError: LocalizedError, Equatable {
        case sourceDirectoryUnavailable

        var errorDescription: String? {
            switch self {
            case .sourceDirectoryUnavailable:
                return "ASTRA could not find a repository capability source directory. Set ASTRA_CAPABILITY_SOURCE_LIBRARY or save the package manually."
            }
        }
    }

    static let sourceLibraryEnvironmentKey = "ASTRA_CAPABILITY_SOURCE_LIBRARY"

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func export(
        _ package: PluginPackage,
        to url: URL? = nil
    ) throws -> URL {
        let destination = try url ?? defaultPackageURL(for: package)
        let manifestDestination = destination.pathExtension == "json"
            ? destination
            : destination.appendingPathComponent(CapabilityPackageSourceReader.manifestFileName)
        try fileManager.createDirectory(
            at: manifestDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if package.iconDescriptor.kind == .asset {
            try copyIconAsset(for: package, toPackageRoot: manifestDestination.deletingLastPathComponent())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Self.sourcePackage(package))
        try data.write(to: manifestDestination, options: [.atomic])
        return manifestDestination
    }

    func defaultPackageURL(for package: PluginPackage) throws -> URL {
        guard let directory = Self.defaultSourceDirectory(fileManager: fileManager) else {
            throw ExportError.sourceDirectoryUnavailable
        }
        return Self.packageURL(for: package, in: directory)
    }

    static func packageURL(for package: PluginPackage, in directory: URL) -> URL {
        directory
            .appendingPathComponent(CapabilityLibrary.safeFileName(for: package.id))
            .appendingPathExtension("json")
    }

    static func sourcePackage(_ package: PluginPackage) -> PluginPackage {
        var source = package
        source.sourceMetadata = .localLibrary()
        source.governance.approvalStatus = .draft
        source.governance.visibility = .adminOnly
        source.governance.requiresAdminApproval = true
        source.governance.requiresExplicitUserConsent = true
        source.governance.approvedBy = nil
        source.governance.approvedAt = nil
        if source.governance.policyNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source.governance.policyNotes = "Local capability package saved from ASTRA and pending review."
        }
        return source
    }

    private func copyIconAsset(
        for package: PluginPackage,
        toPackageRoot packageRoot: URL
    ) throws {
        guard let sourceRoot = assetRootURL(from: package.sourceMetadata?.url) else {
            throw CapabilityIconAssetValidationError.missing
        }
        let sourceAsset = try CapabilityIconAssetPolicy.validatedAssetURL(
            relativePath: package.iconDescriptor.value,
            rootURL: sourceRoot,
            fileManager: fileManager
        )
        let destinationAsset = packageRoot.appendingPathComponent(package.iconDescriptor.value)
        try fileManager.createDirectory(
            at: destinationAsset.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationAsset.path) {
            try fileManager.removeItem(at: destinationAsset)
        }
        try fileManager.copyItem(at: sourceAsset, to: destinationAsset)
    }

    private func assetRootURL(from url: URL?) -> URL? {
        guard let url else { return nil }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory ? url : url.deletingLastPathComponent()
    }

    static func defaultSourceDirectory(
        startingAt startURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment[sourceLibraryEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }

        let bundleCandidates = repositoryRootCandidates(fromBundleURL: bundleURL)
        for root in bundleCandidates {
            if hasCapabilityLibraryRoot(root, fileManager: fileManager) {
                return root
                    .appendingPathComponent("capabilities", isDirectory: true)
                    .appendingPathComponent("local", isDirectory: true)
            }
        }

        var candidate = startURL.standardizedFileURL
        if !isDirectory(candidate, fileManager: fileManager) {
            candidate.deleteLastPathComponent()
        }

        while true {
            if hasCapabilityLibraryRoot(candidate, fileManager: fileManager) {
                return candidate
                    .appendingPathComponent("capabilities", isDirectory: true)
                    .appendingPathComponent("local", isDirectory: true)
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    private static func repositoryRootCandidates(fromBundleURL bundleURL: URL) -> [URL] {
        let standardized = bundleURL.standardizedFileURL
        guard standardized.pathExtension == "app" else {
            return []
        }
        let distDirectory = standardized.deletingLastPathComponent()
        return [
            distDirectory.deletingLastPathComponent(),
            distDirectory
        ]
    }

    private static func hasCapabilityLibraryRoot(_ url: URL, fileManager: FileManager) -> Bool {
        let packageURL = url.appendingPathComponent("Package.swift")
        let capabilitiesURL = url.appendingPathComponent("capabilities", isDirectory: true)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: packageURL.path)
            && fileManager.fileExists(atPath: capabilitiesURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
