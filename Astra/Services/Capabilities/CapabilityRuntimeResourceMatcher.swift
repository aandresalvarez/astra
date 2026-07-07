import Foundation
import ASTRACore
import ASTRAModels

enum CapabilityRuntimeResourceMatcher {
    private static var approvalRecordsLoaderForTesting: (() -> [CapabilityApprovalRecord])?
    private static let approvalRecordsLoaderLock = NSRecursiveLock()

    static func withApprovalRecordsLoaderForTesting<Result>(
        _ loader: @escaping () -> [CapabilityApprovalRecord],
        perform: () throws -> Result
    ) rethrows -> Result {
        approvalRecordsLoaderLock.lock()
        let previousLoader = approvalRecordsLoaderForTesting
        approvalRecordsLoaderForTesting = loader
        defer {
            approvalRecordsLoaderForTesting = previousLoader
            approvalRecordsLoaderLock.unlock()
        }
        return try perform()
    }

    static func packageDefinitions(library: CapabilityLibrary = CapabilityLibrary()) -> [PluginPackage] {
        uniquePackages(cachedInstalledPackages(library: library) + PluginCatalog.builtInPackages)
    }

    static func packageDefinitionsFingerprint(library: CapabilityLibrary = CapabilityLibrary()) -> String {
        let directory = library.directory.standardizedFileURL
        let fingerprint = directoryFingerprint(for: directory)
        let builtInFingerprint = PluginCatalog.builtInPackages
            .map { "\($0.id):\($0.version)" }
            .sorted()
            .joined(separator: ",")
        return [
            directory.path,
            String(fingerprint.fileCount),
            String(fingerprint.latestModificationTime),
            builtInFingerprint
        ].joined(separator: "|")
    }

    static func enabledPackages(
        for workspace: Workspace?,
        library: CapabilityLibrary = CapabilityLibrary(),
        approvalRecords: [CapabilityApprovalRecord]? = nil,
        packPolicy: PackResolvedPolicy? = nil
    ) -> [PluginPackage] {
        guard let workspace else { return [] }
        let enabledIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledIDs.isEmpty else { return [] }
        return packPolicyAllowedPackages(
            packageDefinitions(library: library).filter { enabledIDs.contains($0.id) },
            workspace: workspace,
            approvalRecords: approvalRecords,
            packPolicy: packPolicy,
            resolvePackPolicyIfNeeded: true
        )
    }

    /// Resolves enabled packages from an already-loaded definition list, without
    /// touching the filesystem. SwiftUI `body`-path callers (the right rail) pass
    /// the catalog they have already cached in view state so capability
    /// resolution stays off the synchronous I/O path — the `library`-backed
    /// overload above re-derives the fingerprint on every call, which is fine for
    /// runtime/launch callers but is a per-frame scan when invoked from `body`.
    /// Built-ins are merged in so the result matches `packageDefinitions()`.
    static func enabledPackages(
        for workspace: Workspace?,
        in definitions: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord]? = nil,
        packPolicy: PackResolvedPolicy? = nil
    ) -> [PluginPackage] {
        guard let workspace else { return [] }
        let enabledIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledIDs.isEmpty else { return [] }
        return packPolicyAllowedPackages(
            uniquePackages(definitions + PluginCatalog.builtInPackages)
                .filter { enabledIDs.contains($0.id) },
            workspace: workspace,
            approvalRecords: approvalRecords,
            packPolicy: packPolicy,
            resolvePackPolicyIfNeeded: false
        )
    }

    static func skillMatches(_ pluginSkill: PluginSkill, skill: Skill) -> Bool {
        normalizedName(pluginSkill.name) == normalizedName(skill.name)
    }

    static func connectorMatches(_ pluginConnector: PluginConnector, connector: Connector) -> Bool {
        if normalizedName(pluginConnector.name) == normalizedName(connector.name) {
            return true
        }

        let packageServiceType = normalizedServiceType(pluginConnector.serviceType)
        guard !packageServiceType.isEmpty, packageServiceType != "custom" else {
            return false
        }
        return packageServiceType == normalizedServiceType(connector.serviceType)
    }

    static func toolMatches(_ pluginTool: PluginLocalTool, tool: LocalTool) -> Bool {
        if normalizedName(pluginTool.name) == normalizedName(tool.name) {
            return true
        }
        return normalizedName(pluginTool.toolType) == normalizedName(tool.toolType)
            && normalizedName(pluginTool.command) == normalizedName(tool.command)
            && normalizedName(pluginTool.arguments) == normalizedName(tool.arguments)
    }

    static func normalizedServiceType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct DirectoryFingerprint: Equatable {
        let fileCount: Int
        let latestModificationTime: TimeInterval
    }

    private struct PackageCacheEntry {
        let fingerprint: DirectoryFingerprint
        let packages: [PluginPackage]
    }

    private static let cacheLock = NSLock()
    private static var packageCache: [String: PackageCacheEntry] = [:]

    private static func cachedInstalledPackages(library: CapabilityLibrary) -> [PluginPackage] {
        let directory = library.directory.standardizedFileURL
        let key = directory.path
        let fingerprint = directoryFingerprint(for: directory)

        cacheLock.lock()
        if let cached = packageCache[key], cached.fingerprint == fingerprint {
            cacheLock.unlock()
            return cached.packages
        }
        cacheLock.unlock()

        let packages = library.installedPackages()

        cacheLock.lock()
        packageCache[key] = PackageCacheEntry(fingerprint: fingerprint, packages: packages)
        cacheLock.unlock()

        return packages
    }

    private static func packPolicyAllowedPackages(
        _ packages: [PluginPackage],
        workspace: Workspace,
        approvalRecords: [CapabilityApprovalRecord]?,
        packPolicy suppliedPackPolicy: PackResolvedPolicy?,
        resolvePackPolicyIfNeeded: Bool
    ) -> [PluginPackage] {
        guard !packages.isEmpty else { return [] }
        let packPolicy = suppliedPackPolicy
            ?? (resolvePackPolicyIfNeeded ? PackWorkspacePolicyProvider.resolvedPolicy(for: workspace) : .empty)
        guard packPolicy.affectsCapabilityRuntimeExposure else { return packages }
        let context = CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: resolvedApprovalRecords(
                approvalRecords,
                packages: packages,
                packPolicy: packPolicy
            ),
            packPolicy: packPolicy
        )
        return packages.filter {
            CapabilityCatalogPolicy.decision(for: $0, context: context).canRun
        }
    }

    private static func resolvedApprovalRecords(
        _ approvalRecords: [CapabilityApprovalRecord]?,
        packages: [PluginPackage],
        packPolicy: PackResolvedPolicy
    ) -> [CapabilityApprovalRecord] {
        if let approvalRecords {
            return approvalRecords
        }
        guard needsApprovalRecords(packages: packages, packPolicy: packPolicy) else {
            return []
        }
        approvalRecordsLoaderLock.lock()
        defer { approvalRecordsLoaderLock.unlock() }
        return approvalRecordsLoaderForTesting?() ?? CapabilityApprovalStore().records()
    }

    private static func needsApprovalRecords(packages: [PluginPackage], packPolicy: PackResolvedPolicy) -> Bool {
        if packPolicy.hasReviewGateRules {
            return true
        }
        return packages.contains { package in
            package.governance.approvalStatus != .approved
        }
    }

    private static func directoryFingerprint(for directory: URL) -> DirectoryFingerprint {
        guard let urls = try? HostFileAccessBroker().contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            intent: .astraManagedStorage(root: directory)
        ) else {
            return DirectoryFingerprint(fileCount: 0, latestModificationTime: 0)
        }

        var latestModificationTime: TimeInterval = 0
        var fileCount = 0
        for url in urls {
            // Asset-backed packages (CapabilityLibrary.install(_:) for a
            // package whose icon is .asset) install as a directory holding
            // CapabilityPackageSourceReader.manifestFileName plus the icon
            // file, not a top-level JSON file — mirror installedPackages()'s
            // directory-vs-JSON-file split so those installs/updates/removals
            // change this fingerprint too, instead of only top-level packages.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory == true {
                let manifestURL = url.appendingPathComponent(CapabilityPackageSourceReader.manifestFileName)
                guard let manifestDate = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else {
                    continue
                }
                fileCount += 1
                latestModificationTime = max(latestModificationTime, manifestDate.timeIntervalSince1970)
                continue
            }
            guard url.pathExtension == "json" else { continue }
            fileCount += 1
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            latestModificationTime = max(latestModificationTime, modificationDate.timeIntervalSince1970)
        }

        return DirectoryFingerprint(
            fileCount: fileCount,
            latestModificationTime: latestModificationTime
        )
    }

    private static func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }
}
