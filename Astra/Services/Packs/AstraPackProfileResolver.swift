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
    var diagnostics: [AstraPackProfileDiagnostic]

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
        let coreShelfIDs = Set(coreDescriptors.map(\.id))
        let sortedPacks = enabledPacks.sorted(by: stablePackOrder)
        let packsDeclaringShelfDefaults = sortedPacks.filter { !$0.shelfDefaults.isEmpty }
        var diagnostics: [AstraPackProfileDiagnostic] = []
        var visibleShelfIDs: Set<ShelfID> = packsDeclaringShelfDefaults.isEmpty ? coreShelfIDs : []
        var capabilityPackageIDsByShelfID: [ShelfID: [String]] = [:]

        for pack in packsDeclaringShelfDefaults {
            for shelfDefault in pack.shelfDefaults {
                guard let shelfID = shelfID(forProfileIdentifier: shelfDefault.id),
                      coreShelfIDs.contains(shelfID) else {
                    diagnostics.append(AstraPackProfileDiagnostic(
                        code: .unknownShelfDefaultID,
                        packID: pack.id,
                        shelfID: shelfDefault.id,
                        message: "Pack '\(pack.id)' declares unknown shelf default '\(shelfDefault.id)'."
                    ))
                    continue
                }

                visibleShelfIDs.insert(shelfID)
                appendUnique(
                    pack.capabilityPackageIDs + shelfDefault.capabilityPackageIDs,
                    to: &capabilityPackageIDsByShelfID[shelfID, default: []]
                )
            }
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

        var resolvedVocabulary = coreVocabulary
        for pack in sortedPacks {
            for (key, value) in pack.vocabulary {
                resolvedVocabulary[key] = value
            }
        }

        let branding = sortedPacks.compactMap(\.branding).last
        return AstraPackResolvedProfile(
            visibleShelfIDs: visibleShelfIDs,
            hiddenShelfIDs: coreShelfIDs.subtracting(visibleShelfIDs),
            vocabulary: resolvedVocabulary,
            branding: branding,
            capabilityPackageIDsByShelfID: capabilityPackageIDsByShelfID,
            diagnostics: diagnostics
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

    private static func stablePackOrder(_ lhs: AstraPackManifest, _ rhs: AstraPackManifest) -> Bool {
        let idOrder = lhs.id.localizedCaseInsensitiveCompare(rhs.id)
        if idOrder != .orderedSame {
            return idOrder == .orderedAscending
        }
        return lhs.version.localizedCaseInsensitiveCompare(rhs.version) == .orderedAscending
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
}
