import Foundation
import ASTRACore

enum CapabilityRuntimeResourceMatcher {
    static func packageDefinitions(library: CapabilityLibrary = CapabilityLibrary()) -> [PluginPackage] {
        uniquePackages(cachedInstalledPackages(library: library) + PluginCatalog.builtInPackages)
    }

    static func enabledPackages(
        for workspace: Workspace?,
        library: CapabilityLibrary = CapabilityLibrary()
    ) -> [PluginPackage] {
        guard let workspace else { return [] }
        let enabledIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledIDs.isEmpty else { return [] }
        return packageDefinitions(library: library).filter { enabledIDs.contains($0.id) }
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

    private static func directoryFingerprint(for directory: URL) -> DirectoryFingerprint {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DirectoryFingerprint(fileCount: 0, latestModificationTime: 0)
        }

        var latestModificationTime: TimeInterval = 0
        var fileCount = 0
        for url in urls where url.pathExtension == "json" {
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
