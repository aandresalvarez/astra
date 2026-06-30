import Testing
@testable import ASTRA
import ASTRACore

@Suite("ASTRA Pack Composition")
struct AstraPackCompositionTests {
    @Test("multiple packs resolve shelf order deterministically")
    func multiplePacksResolveShelfOrderDeterministically() {
        let localPack = Self.pack(
            id: "vertical.incident",
            shelfDefaults: [
                Self.shelfDefault(id: "query"),
                Self.shelfDefault(id: "browser")
            ]
        )
        let builtInPack = Self.pack(
            id: "astra.pack.runbooks",
            shelfDefaults: [
                Self.shelfDefault(id: "plan"),
                Self.shelfDefault(id: "files")
            ]
        )

        let result = AstraPackComposition.resolve(inputs: [
            Self.input(localPack, sourceKind: .local),
            Self.input(builtInPack, sourceKind: .builtIn)
        ])

        #expect(result.orderedPackIDs == ["astra.pack.runbooks", "vertical.incident"])
        #expect(result.shelfDefaults.map(\.id) == ["plan", "files", "query", "browser"])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("local astra-like pack ID still composes after built-in source")
    func localAstraLikePackIDStillComposesAfterBuiltInSource() {
        let localPack = Self.pack(
            id: "astra.pack.local-override",
            vocabulary: [
                "task": "Incident"
            ]
        )
        let builtInPack = Self.pack(
            id: "vertical.builtin-source",
            vocabulary: [
                "task": "Task"
            ]
        )

        let result = AstraPackComposition.resolve(inputs: [
            Self.input(localPack, sourceKind: .local),
            Self.input(builtInPack, sourceKind: .builtIn)
        ])

        #expect(result.orderedPackIDs == ["vertical.builtin-source", "astra.pack.local-override"])
        #expect(result.vocabulary["task"] == "Incident")
    }

    @Test("conflicting vocabulary uses highest priority pack")
    func conflictingVocabularyUsesHighestPriorityPack() {
        let corePack = Self.pack(
            id: "astra.pack.core",
            compositionPriority: 10,
            vocabulary: [
                "task": "Task"
            ]
        )
        let verticalPack = Self.pack(
            id: "vertical.incident",
            compositionPriority: 50,
            vocabulary: [
                "task": "Incident"
            ]
        )

        let result = AstraPackComposition.resolve(inputs: [
            Self.input(verticalPack, sourceKind: .local),
            Self.input(corePack, sourceKind: .builtIn)
        ])

        #expect(result.orderedPackIDs == ["astra.pack.core", "vertical.incident"])
        #expect(result.vocabulary["task"] == "Incident")
        #expect(result.diagnostics.contains {
            $0.conflictKind == .vocabulary
                && $0.packIDs == ["astra.pack.core", "vertical.incident"]
                && $0.winningPackID == "vertical.incident"
                && $0.losingPackIDs == ["astra.pack.core"]
        })
    }

    @Test("conflicts produce diagnostics")
    func conflictsProduceDiagnostics() {
        let lowerPriority = Self.pack(
            id: "astra.pack.runbooks",
            compositionPriority: 10,
            shelfDefaults: [
                Self.shelfDefault(id: "plan", title: "Plan")
            ],
            vocabulary: [
                "task": "Task"
            ]
        )
        let higherPriority = Self.pack(
            id: "vertical.incident",
            compositionPriority: 20,
            shelfDefaults: [
                Self.shelfDefault(id: "plan", title: "Incident Plan")
            ],
            vocabulary: [
                "task": "Incident"
            ]
        )

        let result = AstraPackComposition.resolve(packs: [higherPriority, lowerPriority])

        #expect(result.shelfDefaults.map(\.title) == ["Incident Plan"])
        #expect(result.diagnostics.contains {
            $0.conflictKind == .shelfDefault
                && $0.key == "plan"
                && $0.packIDs == ["astra.pack.runbooks", "vertical.incident"]
                && $0.winningPackID == "vertical.incident"
                && $0.losingPackIDs == ["astra.pack.runbooks"]
        })
        #expect(result.diagnostics.contains {
            $0.conflictKind == .vocabulary
                && $0.key == "task"
                && $0.packIDs == ["astra.pack.runbooks", "vertical.incident"]
                && $0.winningPackID == "vertical.incident"
                && $0.losingPackIDs == ["astra.pack.runbooks"]
        })
    }

    @Test("shelf capability conflicts produce diagnostics")
    func shelfCapabilityConflictsProduceDiagnostics() {
        let lowerPriority = Self.pack(
            id: "astra.pack.runbooks",
            compositionPriority: 10,
            capabilityPackageIDs: ["github-read"],
            shelfDefaults: [
                Self.shelfDefault(id: "files", title: "Files")
            ]
        )
        let higherPriority = Self.pack(
            id: "vertical.incident",
            compositionPriority: 20,
            capabilityPackageIDs: ["drive-read"],
            shelfDefaults: [
                Self.shelfDefault(id: "files", title: "Files")
            ]
        )

        let result = AstraPackComposition.resolve(packs: [higherPriority, lowerPriority])

        #expect(result.capabilityPackageIDsByShelfID["files"] == ["github-read", "drive-read"])
        #expect(result.diagnostics.contains {
            $0.conflictKind == .shelfDefault
                && $0.key == "files"
                && $0.winningPackID == "vertical.incident"
                && $0.losingPackIDs == ["astra.pack.runbooks"]
        })
    }

    @Test("policy restrictions merge restrictively")
    func policyRestrictionsMergeRestrictively() {
        let readOnlyPack = Self.pack(
            id: "astra.pack.read-only",
            policyRestrictions: [
                Self.restriction(id: "hide-browser", contributionKind: "shelf", action: "hideShelf", targetID: "browser"),
                Self.restriction(
                    id: "disable-shell",
                    contributionKind: "capabilityPackage",
                    action: "disableCapability",
                    targetID: "builtin.shell"
                )
            ]
        )
        let verticalPack = Self.pack(
            id: "vertical.incident",
            policyRestrictions: [
                Self.restriction(
                    id: "disable-shell-vertical",
                    contributionKind: "capabilityPackage",
                    action: "disableCapability",
                    targetID: "builtin.shell"
                ),
                Self.restriction(
                    id: "disable-network",
                    contributionKind: "capabilityPackage",
                    action: "disableCapability",
                    targetID: "builtin.network"
                )
            ]
        )

        let result = AstraPackComposition.resolve(packs: [verticalPack, readOnlyPack])

        #expect(result.policyRestrictions.map(\.action) == [
            "hideShelf",
            "disableCapability",
            "disableCapability"
        ])
        #expect(result.policyRestrictions.map(\.targetID) == ["browser", "builtin.shell", "builtin.network"])
        #expect(result.policyRestrictions.allSatisfy { $0.effect == "restrict" })
    }

    @Test("profile resolver keeps capabilities from all packs sharing shelf")
    func profileResolverKeepsCapabilitiesFromAllPacksSharingShelf() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(
                    id: "astra.pack.runbooks",
                    compositionPriority: 10,
                    capabilityPackageIDs: ["github-read"],
                    shelfDefaults: [
                        Self.shelfDefault(id: "files", title: "Files")
                    ]
                ),
                Self.pack(
                    id: "vertical.incident",
                    compositionPriority: 20,
                    capabilityPackageIDs: ["drive-read"],
                    shelfDefaults: [
                        Self.shelfDefault(id: "files", title: "Files")
                    ]
                )
            ]
        )

        #expect(profile.capabilityPackageIDsByShelfID[.files] == ["github-read", "drive-read"])
        #expect(profile.compositionDiagnostics.contains {
            $0.conflictKind == .shelfDefault
                && $0.key == "files"
                && $0.winningPackID == "vertical.incident"
        })
    }

    @Test("profile resolver exposes composition diagnostics")
    func profileResolverExposesCompositionDiagnostics() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(
                    id: "astra.pack.core",
                    compositionPriority: 10,
                    vocabulary: ["task": "Task"]
                ),
                Self.pack(
                    id: "vertical.incident",
                    compositionPriority: 20,
                    vocabulary: ["task": "Incident"]
                )
            ]
        )

        #expect(profile.vocabularyValue(for: "task") == "Incident")
        #expect(profile.compositionDiagnostics.contains {
            $0.conflictKind == .vocabulary
                && $0.key == "task"
                && $0.winningPackID == "vertical.incident"
        })
    }

    private static func input(
        _ manifest: AstraPackManifest,
        sourceKind: AstraPackSource.Kind
    ) -> AstraPackCompositionInput {
        AstraPackCompositionInput(manifest: manifest, sourceKind: sourceKind)
    }

    private static func pack(
        id: String,
        compositionPriority: Int? = nil,
        capabilityPackageIDs: [String] = [],
        shelfDefaults: [AstraPackShelfDefault] = [],
        policyRestrictions: [AstraPackPolicyRestriction] = [],
        vocabulary: [String: String] = [:]
    ) -> AstraPackManifest {
        AstraPackManifest(
            id: id,
            name: id,
            version: "1.0.0",
            coreAPIVersion: "1.0",
            description: "Composition test pack.",
            capabilityPackageIDs: capabilityPackageIDs,
            shelfDefaults: shelfDefaults,
            policyRestrictions: policyRestrictions,
            vocabulary: vocabulary,
            compositionPriority: compositionPriority
        )
    }

    private static func shelfDefault(
        id: String,
        title: String? = nil,
        capabilityPackageIDs: [String] = []
    ) -> AstraPackShelfDefault {
        AstraPackShelfDefault(
            id: id,
            title: title ?? id,
            kind: "core",
            capabilityPackageIDs: capabilityPackageIDs
        )
    }

    private static func restriction(
        id: String,
        contributionKind: String = "workspaceApp",
        action: String,
        targetID: String
    ) -> AstraPackPolicyRestriction {
        AstraPackPolicyRestriction(
            id: id,
            contributionKind: contributionKind,
            action: action,
            effect: "restrict",
            targetID: targetID
        )
    }
}
