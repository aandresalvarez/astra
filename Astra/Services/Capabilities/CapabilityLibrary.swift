import Foundation
import ASTRACore

struct CapabilityLibrary {
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
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard var package = try? decoder.decode(PluginPackage.self, from: data) else { return nil }
                if package.sourceMetadata == nil {
                    package.sourceMetadata = .localLibrary()
                }
                if trustedBuiltInIDs.contains(package.id) {
                    // Defense in depth: trusted by ID, but governance still
                    // comes from the compiled definition when one exists.
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
                return package
            }
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
        var storedPackage = package
        if let sourceMetadata {
            storedPackage.sourceMetadata = sourceMetadata
        } else if storedPackage.sourceMetadata == nil {
            storedPackage.sourceMetadata = .localLibrary()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storedPackage)
        try data.write(to: packageURL(for: storedPackage.id), options: [.atomic])
    }

    func seedApprovedPackages(_ packages: [PluginPackage]) throws {
        try ensureDirectoryExists()
        let decoder = JSONDecoder()
        for package in packages {
            let approved = approvedPackage(package)
            let url = packageURL(for: package.id)
            if let data = try? Data(contentsOf: url),
               let existing = try? decoder.decode(PluginPackage.self, from: data),
               shouldPreserveExistingPackage(existing, insteadOf: approved) {
                continue
            }

            try install(approved, sourceMetadata: approved.sourceMetadata)
        }
    }

    func syncApprovedPackages(_ packages: [PluginPackage]) throws {
        try seedApprovedPackages(packages)

        let approvedIDs = Set(packages.map(\.id))
        let decoder = JSONDecoder()
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let package = try? decoder.decode(PluginPackage.self, from: data),
                  package.sourceMetadata?.kind == "built-in",
                  !approvedIDs.contains(package.id) else {
                continue
            }
            try fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    func removePackage(
        id: String,
        trustedBuiltInIDs: Set<String> = CapabilityLibrary.trustedBuiltInPackageIDs
    ) throws -> PluginPackage {
        let url = packageURL(for: id)
        guard let data = try? Data(contentsOf: url) else {
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

        try fileManager.removeItem(at: url)
        return package
    }

    func packageURL(for id: String) -> URL {
        directory.appendingPathComponent(Self.safeFileName(for: id)).appendingPathExtension("json")
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

    private func shouldPreserveExistingPackage(_ existing: PluginPackage, insteadOf approved: PluginPackage) -> Bool {
        if approved.sourceMetadata?.kind == "built-in", existing.sourceMetadata?.kind != "built-in" {
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

    private func canonicalPackageData(_ package: PluginPackage) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(package)
    }
}
