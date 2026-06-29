import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Trusted shelf contributions")
struct TrustedShelfContributionTests {
    @Test("pack can reference trusted native shelf")
    func packCanReferenceTrustedNativeShelf() {
        let manifest = Self.pack(shelfDefaults: [
            AstraPackShelfDefault(
                id: "browser",
                title: "Incident Browser",
                kind: "nativeShelf",
                capabilityPackageIDs: ["builtin.browser"]
            )
        ])

        let report = AstraPackManifestValidator.validate(manifest)
        let profile = AstraPackProfileResolver.resolve(enabledPacks: [manifest])

        #expect(report.isValid)
        #expect(profile.visibleShelfIDs == Set([.browser]))
        #expect(profile.capabilityPackageIDsByShelfID[.browser] == ["builtin.browser"])
    }

    @Test("pack cannot reference unknown native shelf")
    func packCannotReferenceUnknownNativeShelf() {
        let manifest = Self.pack(shelfDefaults: [
            AstraPackShelfDefault(
                id: "incident-feed",
                title: "Incident Feed",
                kind: "nativeShelf"
            )
        ])

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.code == .unknownTrustedShelfID
                && $0.path == "/shelfDefaults/0/id"
        })
    }

    @Test("pack cannot reference core shelf that is not pack addressable")
    func packCannotReferenceCoreShelfThatIsNotPackAddressable() {
        let manifest = Self.pack(shelfDefaults: [
            AstraPackShelfDefault(
                id: "app-preview",
                title: "Preview",
                kind: "nativeShelf"
            )
        ])

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.code == .unaddressableTrustedShelfID
                && $0.path == "/shelfDefaults/0/id"
        })
    }

    @Test("resolver bypass cannot surface non-addressable shelf default")
    func resolverBypassCannotSurfaceNonAddressableShelfDefault() {
        let manifest = Self.pack(shelfDefaults: [
            AstraPackShelfDefault(
                id: "app-preview",
                title: "Preview",
                kind: "nativeShelf"
            )
        ])

        let profile = AstraPackProfileResolver.resolve(enabledPacks: [manifest])

        #expect(profile.visibleShelfIDs.isEmpty)
        #expect(!profile.isShelfVisible(.appPreview))
        #expect(profile.diagnostics.contains {
            $0.code == .unaddressableShelfDefaultID
                && $0.shelfID == "app-preview"
        })
    }

    @Test("profile overrides cannot surface non-addressable shelf")
    func profileOverridesCannotSurfaceNonAddressableShelf() {
        let manifest = Self.pack(shelfDefaults: [
            AstraPackShelfDefault(
                id: "plan",
                title: "Plan",
                kind: "nativeShelf"
            )
        ])

        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [manifest],
            workspaceShelfVisibilityOverrides: ["app-preview": true],
            adminShelfVisibilityOverrides: ["appPreview": true]
        )

        #expect(profile.visibleShelfIDs == Set([.plan]))
        #expect(!profile.isShelfVisible(.appPreview))
        #expect(profile.diagnostics.contains {
            $0.code == .unaddressableShelfOverrideID
                && $0.shelfID == "app-preview"
        })
        #expect(profile.diagnostics.contains {
            $0.code == .unaddressableShelfOverrideID
                && $0.shelfID == "appPreview"
        })
    }

    @Test("pack cannot override core shelf implementation")
    func packCannotOverrideCoreShelfImplementation() {
        for forbiddenKey in Self.forbiddenShelfImplementationKeys {
            let json = """
            {
              "formatVersion": 1,
              "id": "astra.pack.bad-shelf",
              "name": "Bad Shelf",
              "version": "1.0.0",
              "coreAPIVersion": "1.0",
              "description": "Attempts to replace a trusted shelf implementation.",
              "shelfDefaults": [
                {
                  "id": "browser",
                  "title": "Bad Browser",
                  "kind": "nativeShelf",
                  "\(forbiddenKey)": "MaliciousBrowserShelf"
                }
              ]
            }
            """

            #expect(throws: (any Error).self, "Expected decoder to reject \(forbiddenKey)") {
                try JSONDecoder().decode(AstraPackManifest.self, from: Data(json.utf8))
            }
        }
    }

    @Test("validator and profile resolver share core shelf stable IDs")
    func validatorAndProfileResolverShareCoreShelfStableIDs() throws {
        let stableIDs = [
            "plan",
            "files",
            "browser",
            "query",
            "app-preview"
        ]

        for stableID in stableIDs {
            let manifest = Self.pack(shelfDefaults: [
                AstraPackShelfDefault(
                    id: stableID,
                    title: stableID,
                    kind: "nativeShelf"
                )
            ])
            let descriptor = try #require(CoreShelfRegistry.descriptor(forStableID: stableID))
            let report = AstraPackManifestValidator.validate(manifest)
            let profile = AstraPackProfileResolver.resolve(enabledPacks: [manifest])

            #expect(profile.diagnostics.contains {
                $0.code == .unknownShelfDefaultID
                    && $0.shelfID == stableID
            } == false)

            if descriptor.isPackAddressable {
                #expect(report.isValid, "Expected \(stableID) to validate as pack-addressable")
                #expect(profile.visibleShelfIDs == Set([descriptor.id]))
            } else {
                #expect(!report.isValid, "Expected \(stableID) to be rejected as non-addressable")
                #expect(!profile.isShelfVisible(descriptor.id))
                #expect(profile.diagnostics.contains {
                    $0.code == .unaddressableShelfDefaultID
                        && $0.shelfID == stableID
                })
            }
        }
    }

    @Test("trusted shelf uses core session lifecycle")
    func trustedShelfUsesCoreSessionLifecycle() throws {
        let manifest = Self.pack(shelfDefaults: [
            AstraPackShelfDefault(
                id: "browser",
                title: "Incident Browser",
                kind: "nativeShelf"
            )
        ])
        let profile = AstraPackProfileResolver.resolve(enabledPacks: [manifest])
        let policy = ShelfAvailabilityPolicy(disabledShelfIDs: profile.hiddenShelfIDs)

        let descriptor = try #require(CoreShelfRegistry.descriptor(for: .browser))
        #expect(descriptor.title == "Browser")
        #expect(descriptor.isPackAddressable)
        #expect(profile.isShelfVisible(.browser))
        #expect(!policy.canPresent(.browser, in: Self.context()))
        #expect(policy.canPresent(.browser, in: Self.context(hasOpenTaskThread: true)))
    }

    private static func pack(
        shelfDefaults: [AstraPackShelfDefault]
    ) -> AstraPackManifest {
        AstraPackManifest(
            id: "astra.pack.trusted-shelf",
            name: "Trusted Shelf Pack",
            version: "1.0.0",
            coreAPIVersion: "1.0",
            description: "Trusted shelf contribution test pack.",
            shelfDefaults: shelfDefaults
        )
    }

    private static let forbiddenShelfImplementationKeys = [
        "swiftUIViewType",
        "viewImplementation",
        "viewType",
        "modulePath",
        "bundlePath",
        "pluginPath"
    ]

    private static func context(
        hasOpenTaskThread: Bool = false
    ) -> ShelfAvailabilityPolicy.Context {
        ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: hasOpenTaskThread,
            hasWorkspaceContext: false,
            hasPlanContent: false,
            hasFilesShelfContent: false,
            hasQueryShelfContent: false,
            isComposingWorkspaceApp: false,
            activeShelfID: nil
        )
    }
}
