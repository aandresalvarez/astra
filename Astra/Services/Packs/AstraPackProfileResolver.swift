import Foundation
import ASTRACore

struct AstraPackProfileDiagnostic: Equatable, Sendable {
    enum Code: Equatable, Sendable {
        case unknownShelfDefaultID
        case unaddressableShelfDefaultID
        case unknownShelfOverrideID
        case unaddressableShelfOverrideID
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
        let coreDescriptorsByID = Dictionary(uniqueKeysWithValues: coreDescriptors.map { ($0.id, $0) })
        let coreShelfIDs = Set(coreDescriptorsByID.keys)
        let hasShelfDefaults = !composition.shelfDefaults.isEmpty
        let policy = AstraPackPolicyResolver.resolve(composition: composition)
        var diagnostics: [AstraPackProfileDiagnostic] = []
        var visibleShelfIDs: Set<ShelfID> = hasShelfDefaults ? [] : coreShelfIDs
        var explicitlyDisabledShelfIDs: Set<ShelfID> = []
        var capabilityPackageIDsByShelfID: [ShelfID: [String]] = [:]

        for shelfDefault in composition.shelfDefaults {
            guard let shelfID = shelfID(forProfileIdentifier: shelfDefault.id),
                  let descriptor = coreDescriptorsByID[shelfID] else {
                diagnostics.append(AstraPackProfileDiagnostic(
                    code: .unknownShelfDefaultID,
                    packID: winningPackID(forShelfID: shelfDefault.id, in: composition),
                    shelfID: shelfDefault.id,
                    message: "A composed pack profile declares unknown shelf default '\(shelfDefault.id)'."
                ))
                continue
            }
            guard descriptor.isPackAddressable else {
                diagnostics.append(AstraPackProfileDiagnostic(
                    code: .unaddressableShelfDefaultID,
                    packID: winningPackID(forShelfID: shelfDefault.id, in: composition),
                    shelfID: shelfDefault.id,
                    message: "A composed pack profile declares non-pack-addressable shelf default '\(shelfDefault.id)'."
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
            coreDescriptorsByID: coreDescriptorsByID,
            visibleShelfIDs: &visibleShelfIDs,
            explicitlyDisabledShelfIDs: &explicitlyDisabledShelfIDs,
            diagnostics: &diagnostics
        )
        apply(
            visibilityOverrides: adminShelfVisibilityOverrides,
            sourceLabel: "admin",
            coreDescriptorsByID: coreDescriptorsByID,
            visibleShelfIDs: &visibleShelfIDs,
            explicitlyDisabledShelfIDs: &explicitlyDisabledShelfIDs,
            diagnostics: &diagnostics
        )

        visibleShelfIDs.subtract(policy.hiddenShelfIDs)

        var resolvedVocabulary = coreVocabulary
        for key in composition.vocabulary.keys.sorted() {
            resolvedVocabulary[key] = composition.vocabulary[key]
        }

        let branding = composition.orderedPacks.compactMap(\.branding).last
        let profileHiddenShelfIDs = packHiddenShelfIDs(
            visibleShelfIDs: visibleShelfIDs,
            descriptorsByID: coreDescriptorsByID
        ).union(explicitlyDisabledShelfIDs)
        return AstraPackResolvedProfile(
            visibleShelfIDs: visibleShelfIDs,
            hiddenShelfIDs: profileHiddenShelfIDs,
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
        coreDescriptorsByID: [ShelfID: ShelfDescriptor],
        visibleShelfIDs: inout Set<ShelfID>,
        explicitlyDisabledShelfIDs: inout Set<ShelfID>,
        diagnostics: inout [AstraPackProfileDiagnostic]
    ) {
        for rawShelfID in visibilityOverrides.keys.sorted() {
            guard let requestedVisibility = visibilityOverrides[rawShelfID] else { continue }
            guard let shelfID = shelfID(forProfileIdentifier: rawShelfID),
                  let descriptor = coreDescriptorsByID[shelfID] else {
                diagnostics.append(AstraPackProfileDiagnostic(
                    code: .unknownShelfOverrideID,
                    packID: nil,
                    shelfID: rawShelfID,
                    message: "\(sourceLabel.capitalized) override references unknown shelf '\(rawShelfID)'."
                ))
                continue
            }

            guard descriptor.isPackAddressable || !requestedVisibility else {
                diagnostics.append(AstraPackProfileDiagnostic(
                    code: .unaddressableShelfOverrideID,
                    packID: nil,
                    shelfID: rawShelfID,
                    message: "\(sourceLabel.capitalized) override cannot enable non-pack-addressable shelf '\(rawShelfID)'."
                ))
                continue
            }

            if requestedVisibility {
                visibleShelfIDs.insert(shelfID)
                explicitlyDisabledShelfIDs.remove(shelfID)
            } else {
                visibleShelfIDs.remove(shelfID)
                explicitlyDisabledShelfIDs.insert(shelfID)
            }
        }
    }

    private static func appendUnique(_ values: [String], to target: inout [String]) {
        for value in values where !target.contains(value) {
            target.append(value)
        }
    }

    private static func packHiddenShelfIDs(
        visibleShelfIDs: Set<ShelfID>,
        descriptorsByID: [ShelfID: ShelfDescriptor]
    ) -> Set<ShelfID> {
        let packAddressableIDs = Set(
            descriptorsByID.values
                .filter(\.isPackAddressable)
                .map(\.id)
        )
        return packAddressableIDs.subtracting(visibleShelfIDs)
    }

    private static func shelfID(forProfileIdentifier identifier: String) -> ShelfID? {
        CoreShelfRegistry.shelfID(forStableID: identifier)
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
        catalogSnapshot: AstraPackCatalogSnapshot? = nil,
        managedShelfVisibilityOverrides: [String: Bool] = AstraPackManagedProfileOverrides.shelfVisibilityOverrides(),
        coreDescriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors
    ) -> AstraPackResolvedProfile {
        let resolution = enabledPackResolution(for: workspace, catalogSnapshot: catalogSnapshot)
        if !resolution.unresolvedPackIDs.isEmpty {
            return unresolvedEnabledPackProfile(
                unresolvedPackIDs: resolution.unresolvedPackIDs,
                coreDescriptors: coreDescriptors
            )
        }
        return AstraPackProfileResolver.resolve(
            coreDescriptors: coreDescriptors,
            enabledPackEntries: resolution.entries,
            workspaceShelfVisibilityOverrides: workspace?.shelfVisibilityOverrides ?? [:],
            adminShelfVisibilityOverrides: managedShelfVisibilityOverrides
        )
    }

    static func shelfAvailabilityPolicy(
        for workspace: Workspace?,
        catalogSnapshot: AstraPackCatalogSnapshot? = nil,
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

    private struct EnabledPackResolution {
        var entries: [AstraPackCatalogEntry]
        var unresolvedPackIDs: Set<String>
    }

    private static func enabledPackResolution(
        for workspace: Workspace?,
        catalogSnapshot: AstraPackCatalogSnapshot?
    ) -> EnabledPackResolution {
        guard let workspace else {
            return EnabledPackResolution(entries: [], unresolvedPackIDs: [])
        }
        let enabledPackIDs = Set(
            workspace.enabledPackIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !enabledPackIDs.isEmpty else {
            return EnabledPackResolution(entries: [], unresolvedPackIDs: [])
        }
        let snapshot = catalogSnapshot ?? AstraPackCatalog().load()
        let entries = snapshot.entries.filter { enabledPackIDs.contains($0.manifest.id) }
        let resolvedPackIDs = Set(entries.map { $0.manifest.id.trimmingCharacters(in: .whitespacesAndNewlines) })
        return EnabledPackResolution(
            entries: entries,
            unresolvedPackIDs: enabledPackIDs.subtracting(resolvedPackIDs)
        )
    }

    private static func unresolvedEnabledPackProfile(
        unresolvedPackIDs: Set<String>,
        coreDescriptors: [ShelfDescriptor]
    ) -> AstraPackResolvedProfile {
        let packAddressableShelfIDs = Set(
            coreDescriptors
                .filter(\.isPackAddressable)
                .map(\.id)
        )
        return AstraPackResolvedProfile(
            visibleShelfIDs: [],
            hiddenShelfIDs: packAddressableShelfIDs,
            vocabulary: AstraPackProfileResolver.coreVocabulary,
            branding: nil,
            capabilityPackageIDsByShelfID: [:],
            policy: PackResolvedPolicy.unresolvedEnabledPacks(unresolvedPackIDs),
            diagnostics: [],
            compositionDiagnostics: []
        )
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
