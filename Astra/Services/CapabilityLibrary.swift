import Foundation
import ASTRACore

struct CapabilityLibrary {
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

    func installedPackages() -> [PluginPackage] {
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
                return package
            }
            .sorted { lhs, rhs in
                lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending ||
                (lhs.category == rhs.category &&
                 lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending)
            }
    }

    func installedPackage(id: String) -> PluginPackage? {
        installedPackages().first { $0.id == id }
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
            let url = packageURL(for: package.id)
            if let data = try? Data(contentsOf: url),
               let existing = try? decoder.decode(PluginPackage.self, from: data),
               let existingVersion = SemanticVersion(string: existing.version),
               let packageVersion = SemanticVersion(string: package.version),
               existingVersion >= packageVersion {
                continue
            }

            var approved = package
            if approved.sourceMetadata == nil {
                approved.sourceMetadata = .builtIn()
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

    func packageURL(for id: String) -> URL {
        directory.appendingPathComponent(Self.safeFileName(for: id)).appendingPathExtension("json")
    }

    static func safeFileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "capability" : sanitized
    }
}
