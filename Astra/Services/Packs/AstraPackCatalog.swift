import Foundation
import ASTRACore

struct AstraPackCatalogSnapshot: Equatable {
    var entries: [AstraPackCatalogEntry]
    var diagnostics: [AstraPackCatalogDiagnostic]

    var packs: [AstraPackManifest] {
        entries.map(\.manifest)
    }
}

struct AstraPackCatalogEntry: Equatable, Sendable {
    var manifest: AstraPackManifest
    var source: AstraPackSource
}

struct AstraPackCatalogDiagnostic: Equatable {
    enum Code: Equatable {
        case unreadableSource
        case malformedManifest
        case invalidManifest
        case duplicatePackID
    }

    var code: Code
    var source: AstraPackSource
    var message: String
    var validationIssues: [AstraPackManifestValidationReport.Issue]
}

struct AstraPackCatalog {
    var builtInDirectory: URL?
    var localStorageRoot: URL?
    var fileManager: FileManager

    init(
        builtInDirectory: URL? = Self.bundledDirectory(),
        localStorageRoot: URL? = Self.localStorageRoot(),
        fileManager: FileManager = .default
    ) {
        self.builtInDirectory = builtInDirectory
        self.localStorageRoot = localStorageRoot
        self.fileManager = fileManager
    }

    func load() -> AstraPackCatalogSnapshot {
        let builtInSources = AstraPackSource.readJSONFiles(
            in: builtInDirectory,
            kind: .builtIn,
            fileManager: fileManager
        )
        let localSources = AstraPackSource.readJSONFiles(
            in: localStorageRoot,
            kind: .local,
            fileManager: fileManager
        )

        var diagnostics = diagnostics(builtInSources.failures + localSources.failures)
        let decoded = decodeAndValidate(builtInSources.sources + localSources.sources, diagnostics: &diagnostics)
        let entries = deduplicate(decoded, diagnostics: &diagnostics)
            .sorted(by: stableEntryOrder)

        return AstraPackCatalogSnapshot(entries: entries, diagnostics: diagnostics)
    }

    static func bundledDirectory(bundle: Bundle = AstraResourceBundle.current) -> URL? {
        bundle.url(forResource: "Packs", withExtension: nil)
    }

    static func localStorageRoot(
        for channel: AppChannel = .current,
        fileManager: FileManager = .default
    ) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(channel.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Packs", isDirectory: true)
    }

    private func diagnostics(_ failures: [AstraPackSourceReadFailure]) -> [AstraPackCatalogDiagnostic] {
        failures.map { failure in
            AstraPackCatalogDiagnostic(
                code: .unreadableSource,
                source: failure.source,
                message: "Could not read ASTRA pack manifest at \(failure.source.manifestURL?.path ?? "unknown path").",
                validationIssues: []
            )
        }
    }

    private func decodeAndValidate(
        _ sources: [AstraPackSource],
        diagnostics: inout [AstraPackCatalogDiagnostic]
    ) -> [AstraPackCatalogEntry] {
        var entries: [AstraPackCatalogEntry] = []

        for source in sources {
            guard let data = source.rawData else {
                diagnostics.append(AstraPackCatalogDiagnostic(
                    code: .unreadableSource,
                    source: source,
                    message: "ASTRA pack source did not include manifest data.",
                    validationIssues: []
                ))
                continue
            }

            let payload: AstraPackManifestPayload
            do {
                payload = try JSONDecoder().decode(AstraPackManifestPayload.self, from: data)
            } catch {
                diagnostics.append(AstraPackCatalogDiagnostic(
                    code: .malformedManifest,
                    source: source,
                    message: "Could not decode ASTRA pack manifest at \(source.manifestURL?.path ?? "unknown path").",
                    validationIssues: []
                ))
                continue
            }

            let manifest = payload.manifest
            let validation = AstraPackManifestValidator.validate(manifest)
            guard validation.isValid else {
                diagnostics.append(AstraPackCatalogDiagnostic(
                    code: .invalidManifest,
                    source: source,
                    message: "ASTRA pack manifest '\(manifest.id)' is invalid.",
                    validationIssues: validation.issues
                ))
                continue
            }

            entries.append(AstraPackCatalogEntry(manifest: manifest, source: source))
        }

        return entries
    }

    private func deduplicate(
        _ entries: [AstraPackCatalogEntry],
        diagnostics: inout [AstraPackCatalogDiagnostic]
    ) -> [AstraPackCatalogEntry] {
        var keptByID: [String: AstraPackCatalogEntry] = [:]

        for entry in entries {
            guard let kept = keptByID[entry.manifest.id] else {
                keptByID[entry.manifest.id] = entry
                continue
            }

            if entry.source.kind == .builtIn, kept.source.kind == .local {
                keptByID[entry.manifest.id] = entry
                diagnostics.append(duplicateDiagnostic(skipped: kept, kept: entry))
            } else {
                diagnostics.append(duplicateDiagnostic(skipped: entry, kept: kept))
            }
        }

        return Array(keptByID.values)
    }

    private func duplicateDiagnostic(
        skipped: AstraPackCatalogEntry,
        kept: AstraPackCatalogEntry
    ) -> AstraPackCatalogDiagnostic {
        AstraPackCatalogDiagnostic(
            code: .duplicatePackID,
            source: skipped.source,
            message: "Duplicate ASTRA pack ID '\(skipped.manifest.id)' skipped; kept \(sourceLabel(kept.source.kind)) source.",
            validationIssues: []
        )
    }

    private func sourceLabel(_ kind: AstraPackSource.Kind) -> String {
        switch kind {
        case .builtIn:
            return "built-in"
        case .local:
            return "local"
        }
    }

    private func stableEntryOrder(_ lhs: AstraPackCatalogEntry, _ rhs: AstraPackCatalogEntry) -> Bool {
        let idOrder = lhs.manifest.id.localizedCaseInsensitiveCompare(rhs.manifest.id)
        if idOrder != .orderedSame {
            return idOrder == .orderedAscending
        }

        let versionOrder = lhs.manifest.version.localizedCaseInsensitiveCompare(rhs.manifest.version)
        if versionOrder != .orderedSame {
            return versionOrder == .orderedAscending
        }

        return (lhs.source.manifestURL?.path ?? "") < (rhs.source.manifestURL?.path ?? "")
    }
}

private struct AstraPackManifestPayload: Decodable {
    var formatVersion: Int
    var id: String
    var name: String
    var version: String
    var coreAPIVersion: String
    var description: String
    var capabilityPackageIDs: [String]
    var shelfDefaults: [AstraPackShelfDefault]
    var appTemplates: [AstraPackAppTemplate]
    var policyRestrictions: [AstraPackPolicyRestriction]
    var vocabulary: [String: String]
    var branding: AstraPackBranding?

    var manifest: AstraPackManifest {
        AstraPackManifest(
            formatVersion: formatVersion,
            id: id,
            name: name,
            version: version,
            coreAPIVersion: coreAPIVersion,
            description: description,
            capabilityPackageIDs: capabilityPackageIDs,
            shelfDefaults: shelfDefaults,
            appTemplates: appTemplates,
            policyRestrictions: policyRestrictions,
            vocabulary: vocabulary,
            branding: branding
        )
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion
        case id
        case name
        case version
        case coreAPIVersion
        case description
        case capabilityPackageIDs
        case shelfDefaults
        case appTemplates
        case policyRestrictions
        case vocabulary
        case branding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        coreAPIVersion = try container.decode(String.self, forKey: .coreAPIVersion)
        description = try container.decode(String.self, forKey: .description)
        capabilityPackageIDs = try container.decodeIfPresent([String].self, forKey: .capabilityPackageIDs) ?? []
        shelfDefaults = try container.decodeIfPresent([AstraPackShelfDefault].self, forKey: .shelfDefaults) ?? []
        appTemplates = try container.decodeIfPresent([AstraPackAppTemplate].self, forKey: .appTemplates) ?? []
        policyRestrictions = try container.decodeIfPresent(
            [AstraPackPolicyRestriction].self,
            forKey: .policyRestrictions
        ) ?? []
        vocabulary = try container.decodeIfPresent([String: String].self, forKey: .vocabulary) ?? [:]
        branding = try container.decodeIfPresent(AstraPackBranding.self, forKey: .branding)
    }
}
