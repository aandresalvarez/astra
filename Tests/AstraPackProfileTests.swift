import Testing
@testable import ASTRA
import ASTRACore

@Suite("ASTRA Pack Profiles")
struct AstraPackProfileTests {
    @Test("profile defaults hide shelf when pack enabled")
    func profileDefaultsHiddenShelfWhenPackEnabled() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(shelfDefaults: [
                    Self.shelfDefault(id: "plan"),
                    Self.shelfDefault(id: "files"),
                    Self.shelfDefault(id: "query")
                ])
            ]
        )

        #expect(profile.isShelfVisible(.plan))
        #expect(profile.isShelfVisible(.files))
        #expect(profile.isShelfVisible(.query))
        #expect(!profile.isShelfVisible(.browser))
        #expect(!profile.isShelfVisible(.appPreview))
    }

    @Test("workspace override can enable allowed hidden shelf")
    func workspaceOverrideCanEnableAllowedHiddenShelf() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(shelfDefaults: [
                    Self.shelfDefault(id: "plan"),
                    Self.shelfDefault(id: "files")
                ])
            ],
            workspaceShelfVisibilityOverrides: [
                "browser": true
            ]
        )

        #expect(profile.isShelfVisible(.browser))
        #expect(profile.visibleShelfIDs == Set([.plan, .files, .browser]))
    }

    @Test("workspace override cannot enable unknown shelf")
    func workspaceOverrideCannotEnableUnknownShelf() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(shelfDefaults: [
                    Self.shelfDefault(id: "plan")
                ])
            ],
            workspaceShelfVisibilityOverrides: [
                "incident-feed": true
            ]
        )

        #expect(profile.visibleShelfIDs == Set([.plan]))
        #expect(profile.diagnostics.contains {
            $0.code == .unknownShelfOverrideID && $0.shelfID == "incident-feed"
        })
    }

    @Test("multi-pack shelf defaults use union semantics")
    func multiPackShelfDefaultsUseUnionSemantics() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(
                    id: "astra.pack.runbooks",
                    shelfDefaults: [
                        Self.shelfDefault(id: "plan"),
                        Self.shelfDefault(id: "files")
                    ]
                ),
                Self.pack(
                    id: "astra.pack.analytics",
                    shelfDefaults: [
                        Self.shelfDefault(id: "query")
                    ]
                )
            ]
        )

        #expect(profile.visibleShelfIDs == Set([.plan, .files, .query]))
        #expect(profile.hiddenShelfIDs == Set([.browser, .appPreview]))
    }

    @Test("admin overrides win over workspace overrides")
    func adminOverridesWinOverWorkspaceOverrides() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(shelfDefaults: [
                    Self.shelfDefault(id: "plan")
                ])
            ],
            workspaceShelfVisibilityOverrides: [
                "browser": true,
                "query": false
            ],
            adminShelfVisibilityOverrides: [
                "browser": false,
                "query": true
            ]
        )

        #expect(profile.isShelfVisible(.plan))
        #expect(!profile.isShelfVisible(.browser))
        #expect(profile.isShelfVisible(.query))
    }

    @Test("workspace pack state drives shelf availability policy")
    @MainActor
    func workspacePackStateDrivesShelfAvailabilityPolicy() {
        let workspace = Workspace(name: "Profile Policy", primaryPath: "/tmp/profile-policy")
        workspace.enabledPackIDs = ["astra.pack.runbooks"]
        let catalog = AstraPackCatalogSnapshot(entries: [
            AstraPackCatalogEntry(
                manifest: Self.pack(
                    id: "astra.pack.runbooks",
                    shelfDefaults: [
                        Self.shelfDefault(id: "plan")
                    ]
                ),
                source: AstraPackSource(
                    kind: .builtIn,
                    manifestURL: nil,
                    rootURL: nil,
                    displayName: "Test Packs",
                    rawData: nil
                )
            )
        ], diagnostics: [])
        let policy = AstraPackWorkspaceProfileProvider.shelfAvailabilityPolicy(
            for: workspace,
            catalogSnapshot: catalog
        )
        let openTask = ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: true,
            hasWorkspaceContext: true,
            hasPlanContent: true,
            hasFilesShelfContent: true,
            hasQueryShelfContent: true,
            isComposingWorkspaceApp: true,
            activeShelfID: nil
        )

        #expect(policy.canPresent(.plan, in: openTask))
        #expect(!policy.canPresent(.browser, in: openTask))
        #expect(!policy.canPresent(.query, in: openTask))
        #expect(!policy.canPresent(.files, in: openTask))
        #expect(!policy.canPresent(.appPreview, in: openTask))
    }

    @Test("legacy workspace without pack state uses core defaults")
    func legacyWorkspaceWithoutPackStateUsesCoreDefaults() {
        let profile = AstraPackProfileResolver.resolve(enabledPacks: [])

        #expect(profile.visibleShelfIDs == Set(CoreShelfRegistry.allDescriptors.map(\.id)))
        #expect(profile.hiddenShelfIDs.isEmpty)
        #expect(profile.diagnostics.isEmpty)
    }

    @Test("vocabulary resolver returns pack string then core fallback")
    func vocabularyResolverReturnsPackStringThenCoreFallback() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(vocabulary: [
                    "task": "Runbook"
                ])
            ],
            coreVocabulary: [
                "task": "Task",
                "workspace": "Workspace"
            ]
        )

        #expect(profile.vocabularyValue(for: "task") == "Runbook")
        #expect(profile.vocabularyValue(for: "workspace") == "Workspace")
    }

    @Test("profile state cannot make unknown shelf presentable")
    func profileStateCannotMakeUnknownShelfPresentableInPolicy() {
        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [
                Self.pack(shelfDefaults: [
                    Self.shelfDefault(id: "plan"),
                    Self.shelfDefault(id: "incident-feed")
                ])
            ],
            workspaceShelfVisibilityOverrides: [
                "incident-feed": true
            ]
        )
        let policy = ShelfAvailabilityPolicy(disabledShelfIDs: profile.hiddenShelfIDs)
        let openTaskWithPlan = ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: true,
            hasWorkspaceContext: true,
            hasPlanContent: true,
            hasFilesShelfContent: true,
            hasQueryShelfContent: true,
            isComposingWorkspaceApp: true,
            activeShelfID: .query
        )

        #expect(policy.canPresent(.plan, in: openTaskWithPlan))
        #expect(!policy.canPresent(.browser, in: openTaskWithPlan))
        #expect(!policy.canPresent(.query, in: openTaskWithPlan))
        #expect(!policy.canPresent(.files, in: openTaskWithPlan))
        #expect(!policy.canPresent(.appPreview, in: openTaskWithPlan))
        #expect(profile.diagnostics.contains { $0.code == .unknownShelfDefaultID })
        #expect(profile.diagnostics.contains { $0.code == .unknownShelfOverrideID })
    }

    private static func pack(
        id: String = "astra.pack.test",
        shelfDefaults: [AstraPackShelfDefault] = [],
        vocabulary: [String: String] = [:]
    ) -> AstraPackManifest {
        AstraPackManifest(
            id: id,
            name: "Test Pack",
            version: "1.0.0",
            coreAPIVersion: "1.0",
            description: "Profile test pack.",
            capabilityPackageIDs: ["test-capability"],
            shelfDefaults: shelfDefaults,
            vocabulary: vocabulary
        )
    }

    private static func shelfDefault(
        id: String,
        capabilityPackageIDs: [String] = []
    ) -> AstraPackShelfDefault {
        AstraPackShelfDefault(
            id: id,
            title: id,
            kind: "core",
            capabilityPackageIDs: capabilityPackageIDs
        )
    }
}
