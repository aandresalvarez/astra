import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("ASTRA Pack Policy")
struct AstraPackPolicyTests {
    @Test("pack cannot lower core risk level")
    func packCannotLowerCoreRiskLevel() {
        let pack = makePack(restrictions: [
            AstraPackPolicyRestriction(
                id: "lower-risk",
                contributionKind: "capabilityPackage",
                action: "lowerRiskLevel",
                effect: "restrict",
                targetID: "policy-package"
            )
        ])

        let report = AstraPackManifestValidator.validate(pack)
        let policy = AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [pack])
        )

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.policyWidening))
        #expect(policy.disabledCapabilityPackageIDs.isEmpty)
        #expect(policy.evidence.contains { $0.kind == .coreFloor })
        #expect(policy.diagnostics.contains { $0.code == .policyWideningIgnored })
    }

    @Test("pack cannot enable capability blocked by Core")
    func packCannotEnableCapabilityBlockedByCore() {
        let pack = makePack(restrictions: [
            AstraPackPolicyRestriction(
                id: "try-enable",
                contributionKind: "capabilityPackage",
                action: "enableCapability",
                effect: "restrict",
                targetID: "policy-package"
            )
        ])
        let package = makeCapabilityPackage(
            id: "policy-package",
            governance: CapabilityGovernance(
                approvalStatus: .blocked,
                riskLevel: .medium,
                visibility: .everyone,
                requiresAdminApproval: true,
                requiresExplicitUserConsent: false
            )
        )

        let report = AstraPackManifestValidator.validate(pack)
        let policy = AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [pack])
        )
        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id],
                packPolicy: policy
            )
        )

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.policyWidening))
        #expect(!decision.canRun)
        #expect(decision.blockers.contains(.blockedApprovalStatus))
        #expect(!decision.blockers.contains { blocker in
            if case .packPolicyRestricted = blocker { return true }
            return false
        })
    }

    @Test("pack can require explicit consent for external effects")
    func packCanRequireExplicitConsentForExternalEffects() {
        let policy = resolvePolicy(restrictions: [
            AstraPackPolicyRestriction(
                id: "docs-read-consent",
                contributionKind: "workspaceApp",
                action: "requireExplicitConsent",
                effect: "restrict",
                targetMCPServerID: "google",
                targetMCPToolName: "docs.get",
                message: "Google Docs reads need local review in this vertical."
            )
        ])

        let evidence = policy.explicitConsentEvidence(serverID: "google", toolName: "docs.get")

        #expect(evidence?.restrictionID == "docs-read-consent")
        #expect(evidence?.message.contains("Google Docs reads") == true)
        #expect(policy.explicitConsentEvidence(serverID: "google", toolName: "docs.batchUpdate") == nil)
    }

    @Test("pack can hide browser shelf by default")
    func packCanHideBrowserShelfByDefault() {
        let pack = makePack(restrictions: [
            AstraPackPolicyRestriction(
                id: "hide-browser",
                contributionKind: "shelf",
                action: "hideShelf",
                effect: "restrict",
                targetID: "browser",
                message: "This vertical does not use browser shelves."
            )
        ])

        let profile = AstraPackProfileResolver.resolve(
            enabledPacks: [pack],
            workspaceShelfVisibilityOverrides: ["browser": true],
            adminShelfVisibilityOverrides: ["browser": true]
        )
        let policy = ShelfAvailabilityPolicy(disabledShelfIDs: profile.hiddenShelfIDs)

        #expect(profile.policy.hiddenShelfIDs.contains(.browser))
        #expect(!profile.isShelfVisible(.browser))
        #expect(!policy.canPresent(.browser, in: ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: true,
            hasWorkspaceContext: false,
            hasPlanContent: false,
            hasFilesShelfContent: false,
            hasQueryShelfContent: false,
            isComposingWorkspaceApp: false
        )))
    }

    @Test("pack policy decision includes restriction evidence")
    func packPolicyDecisionIncludesRestrictionEvidence() {
        let policy = resolvePolicy(restrictions: [
            AstraPackPolicyRestriction(
                id: "disable-policy-package",
                contributionKind: "capabilityPackage",
                action: "disableCapability",
                effect: "restrict",
                targetID: "policy-package",
                message: "Disabled for regulated workspaces."
            ),
            AstraPackPolicyRestriction(
                id: "warn-policy-tag",
                contributionKind: "capabilityPackage",
                action: "addWarning",
                effect: "restrict",
                targetTag: "regulated",
                message: "Regulated workspace warning."
            ),
            AstraPackPolicyRestriction(
                id: "review-policy-tag",
                contributionKind: "capabilityPackage",
                action: "requireReviewGate",
                effect: "restrict",
                targetTag: "regulated",
                message: "Needs vertical owner review."
            )
        ])
        let package = makeCapabilityPackage(id: "policy-package", tags: ["regulated"])

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id],
                packPolicy: policy
            )
        )

        #expect(!decision.canEnable)
        #expect(!decision.canRun)
        #expect(decision.blockers.contains { blocker in
            if case .packPolicyRestricted(let message) = blocker {
                return message.contains("Disabled for regulated")
            }
            return false
        })
        #expect(decision.blockers.contains { blocker in
            if case .packPolicyReviewRequired(let message) = blocker {
                return message.contains("vertical owner review")
            }
            return false
        })
        #expect(decision.warnings.contains { warning in
            if case .packPolicyWarning(let message) = warning {
                return message.contains("Regulated workspace warning")
            }
            return false
        })
        #expect(decision.policyEvidence.contains { $0.kind == .coreFloor })
        #expect(decision.policyEvidence.contains { $0.restrictionID == "disable-policy-package" })
        #expect(decision.policyEvidence.contains { $0.restrictionID == "warn-policy-tag" })
        #expect(decision.policyEvidence.contains { $0.restrictionID == "review-policy-tag" })
    }

    @Test("workspace policy provider resolves enabled pack policy")
    @MainActor
    func workspacePolicyProviderResolvesEnabledPackPolicy() {
        let workspace = Workspace(name: "Policy Workspace", primaryPath: "/tmp/policy-workspace")
        workspace.enabledPackIDs = ["astra.pack.policy"]
        let policy = PackWorkspacePolicyProvider.resolvedPolicy(
            for: workspace,
            catalogSnapshot: catalogSnapshot(restrictions: [
                AstraPackPolicyRestriction(
                    id: "disable-policy-package",
                    contributionKind: "capabilityPackage",
                    action: "disableCapability",
                    effect: "restrict",
                    targetID: "policy-package"
                )
            ])
        )

        #expect(policy.disabledCapabilityPackageIDs.contains("policy-package"))
        #expect(policy.evidence.contains { $0.restrictionID == "disable-policy-package" })
    }

    @Test("workspace policy provider fails closed when enabled packs are unresolved")
    @MainActor
    func workspacePolicyProviderFailsClosedForUnresolvedEnabledPacks() {
        let workspace = Workspace(name: "Missing Pack Workspace", primaryPath: "/tmp/missing-pack-workspace")
        workspace.enabledCapabilityIDs = ["policy-package"]
        workspace.enabledPackIDs = ["astra.pack.missing"]
        let package = makeCapabilityPackage(id: "policy-package")

        let policy = PackWorkspacePolicyProvider.resolvedPolicy(
            for: workspace,
            catalogSnapshot: AstraPackCatalogSnapshot(entries: [], diagnostics: [])
        )
        let context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: SemanticVersion(1, 0, 0),
            packPolicyResolver: { _ in policy }
        )
        let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
        let runtimePackages = CapabilityRuntimeResourceMatcher.enabledPackages(
            for: workspace,
            in: [package],
            approvalRecords: [],
            packPolicy: policy
        )

        #expect(policy.unresolvedEnabledPackIDs == ["astra.pack.missing"])
        #expect(!decision.canRun)
        #expect(runtimePackages.isEmpty)
        #expect(decision.blockerMessages.contains { $0.contains("enabled pack could not be resolved") })
    }

    @Test("workspace context factory applies resolved pack policy")
    @MainActor
    func workspaceContextFactoryAppliesResolvedPackPolicy() {
        let workspace = Workspace(name: "Policy Factory", primaryPath: "/tmp/policy-factory")
        workspace.enabledCapabilityIDs = ["policy-package"]
        workspace.enabledPackIDs = ["astra.pack.policy"]
        let package = makeCapabilityPackage(id: "policy-package")
        let resolvedPolicy = PackWorkspacePolicyProvider.resolvedPolicy(
            for: workspace,
            catalogSnapshot: catalogSnapshot(restrictions: [
                AstraPackPolicyRestriction(
                    id: "disable-policy-package",
                    contributionKind: "capabilityPackage",
                    action: "disableCapability",
                    effect: "restrict",
                    targetID: "policy-package",
                    message: "Disabled by enabled workspace pack."
                )
            ])
        )
        let context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: SemanticVersion(1, 0, 0),
            packPolicyResolver: { _ in resolvedPolicy }
        )

        let decision = CapabilityCatalogPolicy.decision(for: package, context: context)

        #expect(!decision.canRun)
        #expect(decision.blockers.contains { blocker in
            if case .packPolicyRestricted(let message) = blocker {
                return message.contains("Disabled by enabled workspace pack")
            }
            return false
        })
    }

    @Test("pack review gate can be satisfied by existing approval record")
    func packReviewGateCanBeSatisfiedByApprovalRecord() throws {
        let policy = resolvePolicy(restrictions: [
            AstraPackPolicyRestriction(
                id: "review-policy-package",
                contributionKind: "capabilityPackage",
                action: "requireReviewGate",
                effect: "restrict",
                targetID: "policy-package",
                message: "Needs vertical owner review."
            )
        ])
        let package = makeCapabilityPackage(id: "policy-package")
        let blocked = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id],
                packPolicy: policy
            )
        )
        let approved = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: .approved,
            approvedBy: "Vertical Owner",
            approvedAt: Date(),
            reviewNotes: "Reviewed for this vertical.",
            sourceDigest: try CapabilityApprovalDigest.digest(for: package)
        )
        let allowed = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id],
                approvalRecords: [approved],
                packPolicy: policy
            )
        )

        #expect(!blocked.canRun)
        #expect(blocked.requiresApproval)
        #expect(blocked.blockers.contains { blocker in
            if case .packPolicyReviewRequired = blocker { return true }
            return false
        })
        #expect(allowed.canRun)
        #expect(!allowed.requiresApproval)
        #expect(!allowed.blockers.contains { blocker in
            if case .packPolicyReviewRequired = blocker { return true }
            return false
        })
        #expect(allowed.policyEvidence.contains { $0.restrictionID == "review-policy-package" })
    }

    private func resolvePolicy(restrictions: [AstraPackPolicyRestriction]) -> PackResolvedPolicy {
        AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [
                makePack(restrictions: restrictions)
            ])
        )
    }

    private func catalogSnapshot(restrictions: [AstraPackPolicyRestriction]) -> AstraPackCatalogSnapshot {
        AstraPackCatalogSnapshot(entries: [
            AstraPackCatalogEntry(
                manifest: makePack(restrictions: restrictions),
                source: AstraPackSource(
                    kind: .builtIn,
                    manifestURL: nil,
                    rootURL: nil,
                    displayName: "Test Packs",
                    rawData: nil
                )
            )
        ], diagnostics: [])
    }

    private func makePack(
        id: String = "astra.pack.policy",
        restrictions: [AstraPackPolicyRestriction]
    ) -> AstraPackManifest {
        AstraPackManifest(
            id: id,
            name: "Policy Pack",
            version: "1.0.0",
            coreAPIVersion: "1.0",
            description: "Policy test pack.",
            policyRestrictions: restrictions
        )
    }
}

private func makeCapabilityPackage(
    id: String = "policy-package",
    tags: [String] = [],
    governance: CapabilityGovernance = .builtInApproved(riskLevel: .medium)
) -> PluginPackage {
    PluginPackage(
        id: id,
        name: "Policy Package",
        icon: "puzzlepiece.extension",
        description: "Policy test package",
        author: "Tests",
        category: "Tests",
        tags: tags,
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [],
        templates: [],
        governance: governance
    )
}
