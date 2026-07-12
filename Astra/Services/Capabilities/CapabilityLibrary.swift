import Foundation
import ASTRACore

struct CapabilityLibrary {
    struct PackageStorageSnapshot {
        var id: String
        var jsonURL: URL
        var packageDirectoryURL: URL
        var existingStorageURL: URL?
        var snapshotURL: URL?
    }

    enum RemovalError: Error, Equatable, LocalizedError {
        case notInstalled(String)
        case builtInPackage(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let id):
                return "Capability package \(id) is not installed."
            case .builtInPackage(let name):
                return "\(name) is built in and cannot be removed from the app catalog. Disable it per workspace instead."
            }
        }
    }

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL = Self.capabilitiesDirectory(), fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func capabilitiesDirectory(for channel: AppChannel = .current) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(channel.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Capabilities", isDirectory: true)
    }

    func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Package IDs whose on-disk governance is trusted as shipped: the
    /// app-curated built-in definitions seeded by `syncApprovedPackages`.
    /// Everything else in the library directory is local content whose
    /// self-declared governance is clamped on load — approval for local
    /// packages comes exclusively from digest-bound approval records.
    static var trustedBuiltInPackageIDs: Set<String> {
        Set(PluginCatalog.builtInPackages.map(\.id))
    }

    /// Curated governance by built-in ID. On load, a trusted built-in's
    /// governance comes from the compiled definition, never the disk file —
    /// a hand-edited built-in JSON cannot elevate (or weaken) its own
    /// governance by name alone.
    static var curatedBuiltInGovernance: [String: CapabilityGovernance] {
        Dictionary(
            PluginCatalog.builtInPackages.map { ($0.id, $0.governance) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func installedPackages(
        trustedBuiltInIDs: Set<String> = CapabilityLibrary.trustedBuiltInPackageIDs
    ) -> [PluginPackage] {
        guard let entries = libraryContents(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else {
            return []
        }

        var packagesByID: [String: PluginPackage] = [:]
        for entry in entries {
            if isDirectory(entry),
               let package = decodeInstalledPackage(
                at: entry.appendingPathComponent(CapabilityPackageSourceReader.manifestFileName),
                trustedBuiltInIDs: trustedBuiltInIDs
               ) {
                packagesByID[package.id] = package
                continue
            }

            if entry.pathExtension == "json",
               let package = decodeInstalledPackage(
                at: entry,
                trustedBuiltInIDs: trustedBuiltInIDs
               ),
               packagesByID[package.id] == nil {
                packagesByID[package.id] = package
            }
        }

        return Array(packagesByID.values)
            .sorted { lhs, rhs in
                lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending ||
                (lhs.category == rhs.category &&
                 lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending)
            }
    }

    func installedPackage(
        id: String,
        trustedBuiltInIDs: Set<String> = CapabilityLibrary.trustedBuiltInPackageIDs
    ) -> PluginPackage? {
        installedPackages(trustedBuiltInIDs: trustedBuiltInIDs).first { $0.id == id }
    }

    func installedVersion(of id: String) -> String? {
        installedPackage(id: id)?.version
    }

    func hasUpdate(for package: PluginPackage) -> Bool {
        guard let installed = installedVersion(of: package.id) else { return false }
        if let installedVersion = SemanticVersion(string: installed),
           let candidateVersion = SemanticVersion(string: package.version) {
            return candidateVersion > installedVersion
        }
        return package.version != installed
    }

    func install(
        _ package: PluginPackage,
        sourceMetadata: CapabilitySourceMetadata? = nil
    ) throws {
        try ensureDirectoryExists()
        let packageAssetRootURL = assetRootURL(from: package.sourceMetadata?.url)
        var storedPackage = package
        if let sourceMetadata {
            storedPackage.sourceMetadata = sourceMetadata
        } else if storedPackage.sourceMetadata == nil {
            storedPackage.sourceMetadata = .localLibrary()
        }

        if storedPackage.iconDescriptor.kind == .asset {
            try install(CapabilityPackageSource(
                package: storedPackage,
                manifestURL: nil,
                assetRootURL: assetRootURL(from: storedPackage.sourceMetadata?.url) ?? packageAssetRootURL
            ))
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storedPackage)
        try removeItemIfPresent(at: packageManifestURL(for: storedPackage.id).deletingLastPathComponent())
        try data.write(to: packageURL(for: storedPackage.id), options: [.atomic])
    }

    func install(_ source: CapabilityPackageSource) throws {
        var storedPackage = source.package
        if storedPackage.sourceMetadata == nil {
            storedPackage.sourceMetadata = .localLibrary()
        }

        guard storedPackage.iconDescriptor.kind == .asset else {
            try install(storedPackage)
            return
        }

        let manifestURL = packageManifestURL(for: storedPackage.id)
        let packageDirectory = manifestURL.deletingLastPathComponent()
        try removeItemIfPresent(at: packageURL(for: storedPackage.id))
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        guard let assetRootURL = source.assetRootURL else {
            throw CapabilityIconAssetValidationError.missing
        }
        let sourceAssetURL = try CapabilityIconAssetPolicy.validatedAssetURL(
            relativePath: storedPackage.iconDescriptor.value,
            rootURL: assetRootURL,
            fileManager: fileManager
        )
        let destinationAssetURL = packageDirectory.appendingPathComponent(storedPackage.iconDescriptor.value)
        try fileManager.createDirectory(
            at: destinationAssetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !sameFile(sourceAssetURL, destinationAssetURL) {
            if fileManager.fileExists(atPath: destinationAssetURL.path) {
                try fileManager.removeItem(at: destinationAssetURL)
            }
            try fileManager.copyItem(at: sourceAssetURL, to: destinationAssetURL)
        }

        storedPackage.sourceMetadata?.url = manifestURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storedPackage)
        try data.write(to: manifestURL, options: [.atomic])
    }

    @discardableResult
    func seedApprovedPackages(_ packages: [PluginPackage]) throws -> Bool {
        try ensureDirectoryExists()
        let decoder = JSONDecoder()
        var changed = false
        for package in packages {
            let approved = approvedPackage(package)
            let url = packageStorageURL(for: package.id)
            if let data = readLibraryData(at: url),
               let existing = try? decoder.decode(PluginPackage.self, from: data),
               shouldPreserveExistingPackage(existing, insteadOf: approved, storageURL: url) {
                continue
            }

            try install(approved, sourceMetadata: approved.sourceMetadata)
            changed = true
        }
        return changed
    }

    @discardableResult
    func syncApprovedPackages(_ packages: [PluginPackage]) throws -> Bool {
        var changed = try seedApprovedPackages(packages)

        let approvedIDs = Set(packages.map(\.id))
        let decoder = JSONDecoder()
        let files = libraryContents(
            at: directory,
            includingPropertiesForKeys: nil
        ) ?? []

        for url in files {
            let manifestURL: URL
            let storageURL: URL
            if isDirectory(url) {
                manifestURL = url.appendingPathComponent(CapabilityPackageSourceReader.manifestFileName)
                storageURL = url
            } else if url.pathExtension == "json" {
                manifestURL = url
                storageURL = url
            } else {
                continue
            }

            guard let data = readLibraryData(at: manifestURL),
                  let package = try? decoder.decode(PluginPackage.self, from: data),
                  package.sourceMetadata?.kind == "built-in",
                  !approvedIDs.contains(package.id) else {
                continue
            }
            try fileManager.removeItem(at: storageURL)
            changed = true
        }
        return changed
    }

    @discardableResult
    func removePackage(
        id: String,
        trustedBuiltInIDs: Set<String> = CapabilityLibrary.trustedBuiltInPackageIDs
    ) throws -> PluginPackage {
        let url = installedPackageStorageURL(for: id)
        guard let data = readLibraryData(at: url) else {
            throw RemovalError.notInstalled(id)
        }

        var package = try JSONDecoder().decode(PluginPackage.self, from: data)
        if package.sourceMetadata == nil {
            package.sourceMetadata = .localLibrary()
        }

        // The trust boundary is the curated built-in ID set, never the disk
        // metadata: keying off `sourceMetadata.kind` would let a tampered
        // file flip its own `kind` to "local" and remove a genuine built-in.
        // A file merely claiming built-in kind whose ID is not curated is
        // local content and remains removable.
        if trustedBuiltInIDs.contains(package.id) {
            throw RemovalError.builtInPackage(package.name)
        }

        if url.lastPathComponent == CapabilityPackageSourceReader.manifestFileName {
            try fileManager.removeItem(at: url.deletingLastPathComponent())
        } else {
            try fileManager.removeItem(at: url)
        }
        return package
    }

    func packageURL(for id: String) -> URL {
        directory.appendingPathComponent(Self.safeFileName(for: id)).appendingPathExtension("json")
    }

    func packageManifestURL(for id: String) -> URL {
        directory
            .appendingPathComponent(Self.safeFileName(for: id), isDirectory: true)
            .appendingPathComponent(CapabilityPackageSourceReader.manifestFileName)
    }

    func packageStorageURL(for id: String) -> URL {
        installedPackageStorageURL(for: id)
    }

    func makePackageStorageSnapshot(for id: String) -> PackageStorageSnapshot {
        let jsonURL = packageURL(for: id)
        let manifestURL = packageManifestURL(for: id)
        let packageDirectoryURL = manifestURL.deletingLastPathComponent()
        let existingStorageURL: URL?
        if fileManager.fileExists(atPath: manifestURL.path) {
            existingStorageURL = packageDirectoryURL
        } else if fileManager.fileExists(atPath: jsonURL.path) {
            existingStorageURL = jsonURL
        } else {
            existingStorageURL = nil
        }

        guard let existingStorageURL else {
            return PackageStorageSnapshot(
                id: id,
                jsonURL: jsonURL,
                packageDirectoryURL: packageDirectoryURL,
                existingStorageURL: nil,
                snapshotURL: nil
            )
        }

        let snapshotDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("astra-capability-snapshot-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = snapshotDirectory.appendingPathComponent(existingStorageURL.lastPathComponent)
        do {
            try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: existingStorageURL, to: snapshotURL)
            return PackageStorageSnapshot(
                id: id,
                jsonURL: jsonURL,
                packageDirectoryURL: packageDirectoryURL,
                existingStorageURL: existingStorageURL,
                snapshotURL: snapshotURL
            )
        } catch {
            try? fileManager.removeItem(at: snapshotDirectory)
            return PackageStorageSnapshot(
                id: id,
                jsonURL: jsonURL,
                packageDirectoryURL: packageDirectoryURL,
                existingStorageURL: existingStorageURL,
                snapshotURL: nil
            )
        }
    }

    func restorePackageStorage(_ snapshot: PackageStorageSnapshot) {
        guard let snapshotURL = snapshot.snapshotURL else {
            if snapshot.existingStorageURL == nil {
                removePackageStorage(jsonURL: snapshot.jsonURL, packageDirectoryURL: snapshot.packageDirectoryURL)
            }
            return
        }

        removePackageStorage(jsonURL: snapshot.jsonURL, packageDirectoryURL: snapshot.packageDirectoryURL)
        if let existingStorageURL = snapshot.existingStorageURL {
            try? fileManager.copyItem(at: snapshotURL, to: existingStorageURL)
        }
        try? fileManager.removeItem(at: snapshotURL.deletingLastPathComponent())
    }

    static func safeFileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "capability" : sanitized
    }

    private func approvedPackage(_ package: PluginPackage) -> PluginPackage {
        var approved = package
        if approved.sourceMetadata == nil {
            approved.sourceMetadata = .builtIn()
        }
        return approved
    }

    private func installedPackageStorageURL(for id: String) -> URL {
        let manifestURL = packageManifestURL(for: id)
        if fileManager.fileExists(atPath: manifestURL.path) {
            return manifestURL
        }
        return packageURL(for: id)
    }

    private func readLibraryData(at url: URL) -> Data? {
        try? HostFileAccessBroker(fileManager: fileManager).readData(
            at: url,
            intent: .astraManagedStorage(root: directory)
        )
    }

    private func libraryContents(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) -> [URL]? {
        try? HostFileAccessBroker(fileManager: fileManager).contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask,
            intent: .astraManagedStorage(root: directory)
        )
    }

    private func assetRootURL(from url: URL?) -> URL? {
        guard let url else { return nil }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory ? url : url.deletingLastPathComponent()
    }

    private func decodeInstalledPackage(
        at url: URL,
        trustedBuiltInIDs: Set<String>
    ) -> PluginPackage? {
        guard let data = readLibraryData(at: url) else { return nil }
        guard var package = try? JSONDecoder().decode(PluginPackage.self, from: data) else { return nil }
        if package.sourceMetadata == nil {
            package.sourceMetadata = .localLibrary()
        }
        let hasAssetIcon = package.iconDescriptor.kind == .asset
        if trustedBuiltInIDs.contains(package.id) {
            // Defense in depth: trusted by ID, but governance still comes from
            // the compiled definition when one exists.
            if let curated = Self.curatedBuiltInGovernance[package.id] {
                package.governance = curated
            }
        } else if CapabilityGovernanceNormalizer.clampToLocalDraft(&package) {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "library_load",
                "package_id": package.id,
                "result": "self_declared_governance_clamped"
            ], level: .warning)
        }
        if hasAssetIcon {
            package.sourceMetadata?.url = url
        }
        return package
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func shouldPreserveExistingPackage(
        _ existing: PluginPackage,
        insteadOf approved: PluginPackage,
        storageURL: URL
    ) -> Bool {
        if approved.sourceMetadata?.kind == "built-in", existing.sourceMetadata?.kind != "built-in" {
            return false
        }

        if approved.iconDescriptor.kind == .asset,
           !storedIconAssetIsValid(for: existing, storageURL: storageURL) {
            return false
        }

        if let existingVersion = SemanticVersion(string: existing.version),
           let approvedVersion = SemanticVersion(string: approved.version) {
            if existingVersion > approvedVersion {
                return true
            }
            if existingVersion < approvedVersion {
                return false
            }
        } else if existing.version != approved.version {
            return false
        }

        return canonicalPackageData(existing) == canonicalPackageData(approved)
    }

    private func storedIconAssetIsValid(for package: PluginPackage, storageURL: URL) -> Bool {
        guard package.iconDescriptor.kind == .asset else { return true }
        let packageRoot = storageURL.deletingLastPathComponent()
        return (try? CapabilityIconAssetPolicy.validatedAssetURL(
            relativePath: package.iconDescriptor.value,
            rootURL: packageRoot,
            fileManager: fileManager
        )) != nil
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path ==
            rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func canonicalPackageData(_ package: PluginPackage) -> Data? {
        var package = package
        package.sourceMetadata?.url = nil
        package.sourceMetadata?.lastRefreshedAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(package)
    }

    private func removePackageStorage(jsonURL: URL, packageDirectoryURL: URL) {
        try? fileManager.removeItem(at: jsonURL)
        try? fileManager.removeItem(at: packageDirectoryURL)
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
