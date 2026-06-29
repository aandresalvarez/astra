import Foundation
import ASTRACore

struct AstraPackProfileDiagnostic: Equatable, Sendable {
    enum Code: Equatable, Sendable {
        case unknownShelfDefaultID
        case unknownShelfOverrideID
    }

    var code: Code
    var packID: String?
    var shelfID: String
    var message: String
}

struct AstraPackResolvedProfile: Equatable {
    var visibleShelfIDs: Set<ShelfID>
    var hiddenShelfIDs: Set<ShelfID>
    var vocabulary: [String: String]
    var branding: AstraPackBranding?
    var capabilityPackageIDsByShelfID: [ShelfID: [String]]
    var policy: PackResolvedPolicy
    var diagnostics: [AstraPackProfileDiagnostic]
    var compositionDiagnostics: [AstraPackCompositionDiagnostic]

    func isShelfVisible(_ shelfID: ShelfID) -> Bool {
        visibleShelfIDs.contains(shelfID)
    }

    func vocabularyValue(for key: String) -> String {
        vocabulary[key] ?? key
    }
}

enum AstraPackProfileResolver {
    static let coreVocabulary: [String: String] = [
        "app": "App",
        "task": "Task",
        "workspace": "Workspace"
    ]

    static func resolve(
        coreDescriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors,
        enabledPacks: [AstraPackManifest],
        workspaceShelfVisibilityOverrides: [String: Bool] = [:],
        adminShelfVisibilityOverrides: [String: Bool] = [:],
        coreVocabulary: [String: String] = Self.coreVocabulary
    ) -> AstraPackResolvedProfile {
        resolve(
            coreDescriptors: coreDescriptors,
            composition: AstraPackComposition.resolve(packs: enabledPacks),
            workspaceShelfVisibilityOverrides: workspaceShelfVisibilityOverrides,
            adminShelfVisibilityOverrides: adminShelfVisibilityOverrides,
            coreVocabulary: coreVocabulary
        )
    }

    static func resolve(
        coreDescriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors,
        enabledPackEntries: [AstraPackCatalogEntry],
        workspaceShelfVisibilityOverrides: [String: Bool] = [:],
        adminShelfVisibilityOverrides: [String: Bool] = [:],
        coreVocabulary: [String: String] = Self.coreVocabulary
    ) -> AstraPackResolvedProfile {
        resolve(
            coreDescriptors: coreDescriptors,
            composition: AstraPackComposition.resolve(entries: enabledPackEntries),
            workspaceShelfVisibilityOverrides: workspaceShelfVisibilityOverrides,
            adminShelfVisibilityOverrides: adminShelfVisibilityOverrides,
            coreVocabulary: coreVocabulary
        )
    }

    private static func resolve(
        coreDescriptors: [ShelfDescriptor],
        composition: AstraPackCompositionResult,
        workspaceShelfVisibilityOverrides: [String: Bool],
        adminShelfVisibilityOverrides: [String: Bool],
        coreVocabulary: [String: String]
    ) -> AstraPackResolvedProfile {
        let coreShelfIDs = Set(coreDescriptors.map(\.id))
        let hasShelfDefaults = !composition.shelfDefaults.isEmpty
        let policy = AstraPackPolicyResolver.resolve(composition: composition)
        var diagnostics: [AstraPackProfileDiagnostic] = []
        var visibleShelfIDs: Set<ShelfID> = hasShelfDefaults ? [] : coreShelfIDs
        var capabilityPackageIDsByShelfID: [ShelfID: [String]] = [:]

        for shelfDefault in composition.shelfDefaults {
            guard let shelfID = shelfID(forProfileIdentifier: shelfDefault.id),
                  coreShelfIDs.contains(shelfID) else {
                diagnostics.append(AstraPackProfileDiagnostic(
                    code: .unknownShelfDefaultID,
                    packID: winningPackID(forShelfID: shelfDefault.id, in: composition),
                    shelfID: shelfDefault.id,
                    message: "A composed pack profile declares unknown shelf default '\(shelfDefault.id)'."
                ))
                continue
            }

            visibleShelfIDs.insert(shelfID)
            appendUnique(
                composition.capabilityPackageIDsByShelfID[shelfDefault.id] ?? shelfDefault.capabilityPackageIDs,
                to: &capabilityPackageIDsByShelfID[shelfID, default: []]
            )
        }

        apply(
            visibilityOverrides: workspaceShelfVisibilityOverrides,
            sourceLabel: "workspace",
            coreShelfIDs: coreShelfIDs,
            visibleShelfIDs: &visibleShelfIDs,
            diagnostics: &diagnostics
        )
        apply(
            visibilityOverrides: adminShelfVisibilityOverrides,
            sourceLabel: "admin",
            coreShelfIDs: coreShelfIDs,
            visibleShelfIDs: &visibleShelfIDs,
            diagnostics: &diagnostics
        )

        visibleShelfIDs.subtract(policy.hiddenShelfIDs)

        var resolvedVocabulary = coreVocabulary
        for key in composition.vocabulary.keys.sorted() {
            resolvedVocabulary[key] = composition.vocabulary[key]
        }

        let branding = composition.orderedPacks.compactMap(\.branding).last
        return AstraPackResolvedProfile(
            visibleShelfIDs: visibleShelfIDs,
            hiddenShelfIDs: coreShelfIDs.subtracting(visibleShelfIDs),
            vocabulary: resolvedVocabulary,
            branding: branding,
            capabilityPackageIDsByShelfID: capabilityPackageIDsByShelfID,
            policy: policy,
            diagnostics: diagnostics,
            compositionDiagnostics: composition.diagnostics
        )
    }

    private static func apply(
        visibilityOverrides: [String: Bool],
        sourceLabel: String,
        coreShelfIDs: Set<ShelfID>,
        visibleShelfIDs: inout Set<ShelfID>,
        diagnostics: inout [AstraPackProfileDiagnostic]
    ) {
        for rawShelfID in visibilityOverrides.keys.sorted() {
            guard let requestedVisibility = visibilityOverrides[rawShelfID] else { continue }
            guard let shelfID = shelfID(forProfileIdentifier: rawShelfID),
                  coreShelfIDs.contains(shelfID) else {
                diagnostics.append(AstraPackProfileDiagnostic(
                    code: .unknownShelfOverrideID,
                    packID: nil,
                    shelfID: rawShelfID,
                    message: "\(sourceLabel.capitalized) override references unknown shelf '\(rawShelfID)'."
                ))
                continue
            }

            if requestedVisibility {
                visibleShelfIDs.insert(shelfID)
            } else {
                visibleShelfIDs.remove(shelfID)
            }
        }
    }

    private static func appendUnique(_ values: [String], to target: inout [String]) {
        for value in values where !target.contains(value) {
            target.append(value)
        }
    }

    private static func shelfID(forProfileIdentifier identifier: String) -> ShelfID? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = ShelfID(rawValue: trimmed) {
            return exact
        }

        switch trimmed {
        case "app-preview":
            return .appPreview
        default:
            return nil
        }
    }

    private static func winningPackID(forShelfID shelfID: String, in composition: AstraPackCompositionResult) -> String? {
        composition.orderedPacks.last { pack in
            pack.shelfDefaults.contains { $0.id == shelfID }
        }?.id
    }
}

enum AstraPackWorkspaceProfileProvider {
    static func resolvedProfile(
        for workspace: Workspace?,
        catalogSnapshot: AstraPackCatalogSnapshot = AstraPackCatalog().load(),
        managedShelfVisibilityOverrides: [String: Bool] = AstraPackManagedProfileOverrides.shelfVisibilityOverrides(),
        coreDescriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors
    ) -> AstraPackResolvedProfile {
        AstraPackProfileResolver.resolve(
            coreDescriptors: coreDescriptors,
            enabledPackEntries: enabledPackEntries(for: workspace, in: catalogSnapshot),
            workspaceShelfVisibilityOverrides: workspace?.shelfVisibilityOverrides ?? [:],
            adminShelfVisibilityOverrides: managedShelfVisibilityOverrides
        )
    }

    static func shelfAvailabilityPolicy(
        for workspace: Workspace?,
        catalogSnapshot: AstraPackCatalogSnapshot = AstraPackCatalog().load(),
        managedShelfVisibilityOverrides: [String: Bool] = AstraPackManagedProfileOverrides.shelfVisibilityOverrides(),
        coreDescriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors
    ) -> ShelfAvailabilityPolicy {
        let profile = resolvedProfile(
            for: workspace,
            catalogSnapshot: catalogSnapshot,
            managedShelfVisibilityOverrides: managedShelfVisibilityOverrides,
            coreDescriptors: coreDescriptors
        )
        return ShelfAvailabilityPolicy(
            descriptors: coreDescriptors,
            disabledShelfIDs: profile.hiddenShelfIDs
        )
    }

    private static func enabledPackEntries(
        for workspace: Workspace?,
        in catalogSnapshot: AstraPackCatalogSnapshot
    ) -> [AstraPackCatalogEntry] {
        guard let workspace else { return [] }
        let enabledPackIDs = Set(
            workspace.enabledPackIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !enabledPackIDs.isEmpty else { return [] }
        return catalogSnapshot.entries.filter { enabledPackIDs.contains($0.manifest.id) }
    }
}

enum AstraPackManagedProfileOverrides {
    static func shelfVisibilityOverrides(defaults: UserDefaults = .standard) -> [String: Bool] {
        guard let rawOverrides = defaults.dictionary(forKey: AppStorageKeys.managedShelfVisibilityOverrides) else {
            return [:]
        }

        var overrides: [String: Bool] = [:]
        for (key, value) in rawOverrides {
            if let boolValue = value as? Bool {
                overrides[key] = boolValue
            } else if let numberValue = value as? NSNumber {
                overrides[key] = numberValue.boolValue
            } else if let stringValue = value as? String,
                      let boolValue = boolValue(from: stringValue) {
                overrides[key] = boolValue
            }
        }
        return overrides
    }

    private static func boolValue(from value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }
}
