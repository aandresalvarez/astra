import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("PluginPackage governance")
struct PluginPackageGovernanceTests {
    @Test("Programmatic packages default to local draft governance")
    func programmaticPackagesDefaultToLocalDraftGovernance() {
        let package = PluginPackage(
            id: "local-example",
            name: "Local Example",
            icon: "puzzlepiece.extension",
            description: "Local package",
            author: "Tests",
            category: "Custom",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        #expect(package.governance.approvalStatus == .draft)
        #expect(package.governance.visibility == .adminOnly)
        #expect(package.governance.requiresAdminApproval)
        #expect(package.governance.requiresExplicitUserConsent)
    }

    @Test("Legacy JSON without governance decodes with conservative local defaults")
    func legacyJSONWithoutGovernanceUsesConservativeDefaults() throws {
        let legacy = """
        {
          "id": "legacy-pkg",
          "name": "Legacy",
          "icon": "star",
          "description": "from before",
          "author": "ASTRA",
          "category": "Other",
          "tags": [],
          "version": "1.0.0",
          "skills": [],
          "connectors": [],
          "localTools": [],
          "templates": []
        }
        """.data(using: .utf8)!

        let package = try JSONDecoder().decode(PluginPackage.self, from: legacy)

        #expect(package.sourceMetadata == nil)
        #expect(package.governance.approvalStatus == .draft)
        #expect(package.governance.riskLevel == .medium)
        #expect(package.governance.visibility == .adminOnly)
    }

    @Test("Built-in source without explicit governance decodes as approved")
    func builtInSourceWithoutExplicitGovernanceUsesApprovedDefault() throws {
        let json = """
        {
          "id": "builtin-pkg",
          "name": "Built In",
          "icon": "star",
          "description": "built in",
          "author": "ASTRA",
          "category": "Other",
          "tags": [],
          "version": "1.0.0",
          "skills": [],
          "connectors": [],
          "localTools": [],
          "templates": [],
          "sourceMetadata": {
            "id": "built-in",
            "displayName": "Built-in Capabilities",
            "kind": "built-in",
            "trustLevel": "built-in"
          }
        }
        """.data(using: .utf8)!

        let package = try JSONDecoder().decode(PluginPackage.self, from: json)

        #expect(package.governance.approvalStatus == .approved)
        #expect(package.governance.visibility == .everyone)
        #expect(!package.governance.requiresAdminApproval)
    }

    @Test("Explicit governance round trips")
    func explicitGovernanceRoundTrips() throws {
        let governance = CapabilityGovernance.builtInApproved(
            riskLevel: .restricted,
            dataAccess: [.connectorCredentials, .clinicalData],
            externalEffects: [.readOnly, .externalAPIWrite],
            allowedRoles: ["researcher"],
            visibility: .roleScoped,
            policyNotes: "Research-only package"
        )
        let package = PluginPackage(
            id: "research-tool",
            name: "Research Tool",
            icon: "cross.case",
            description: "Research package",
            author: "Tests",
            category: "Research",
            tags: ["research"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: governance
        )

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)

        #expect(decoded.governance == governance)
        #expect(decoded.governance.allowedRoles == ["researcher"])
        #expect(decoded.governance.dataAccess == [.connectorCredentials, .clinicalData])
    }

    @Test("Audit package fields include compact governance posture")
    @MainActor
    func auditPackageFieldsIncludeGovernancePosture() {
        let workspace = Workspace(name: "Audit", primaryPath: "/tmp/audit")
        let governance = CapabilityGovernance.builtInApproved(
            riskLevel: .high,
            dataAccess: [.network],
            externalEffects: [.externalAPIWrite],
            policyNotes: "Audited package"
        )

        let fields = CapabilityAudit.packageFields(
            packageID: "audit-capability",
            packageName: "Audit Capability",
            packageVersion: "1.0.0",
            workspace: workspace,
            source: "test",
            skillsCount: 1,
            connectorsCount: 1,
            toolsCount: 0,
            governance: governance
        )

        #expect(fields["approval_status"] == "approved")
        #expect(fields["risk_level"] == "high")
        #expect(fields["visibility"] == "everyone")
        #expect(fields["requires_admin_approval"] == "false")
        #expect(fields["requires_explicit_user_consent"] == "false")
    }

    @Test("Approved built-in resources declare explicit governance")
    @MainActor
    func approvedBuiltInResourcesDeclareGovernance() throws {
        let packages = PluginCatalog.builtInPackages

        #expect(!packages.isEmpty)
        for package in packages {
            #expect(package.governance.approvalStatus == .approved, "\(package.id) should be approved")
            #expect(package.governance.visibility == .everyone, "\(package.id) should be visible by default")
            #expect(package.governance.approvedBy == "ASTRA", "\(package.id) should record the approving authority")
            #expect(!package.governance.dataAccess.isEmpty || !package.governance.externalEffects.isEmpty, "\(package.id) should document access or effects")
        }
    }

    @Test("Sensitive built-ins carry high or restricted risk")
    @MainActor
    func sensitiveBuiltInsCarryRiskLabels() throws {
        let packages = Dictionary(uniqueKeysWithValues: PluginCatalog.builtInPackages.map { ($0.id, $0) })

        #expect(packages["github-workflow"]?.governance.riskLevel == .high)
        #expect(packages["google-drive-browser"]?.governance.riskLevel == .high)
        #expect(packages["redcap-workflow"]?.governance.riskLevel == .restricted)
        #expect(packages["gcloud-workflow"]?.governance.riskLevel == .restricted)
        #expect(packages["stanford-healthcare-graph-mail"]?.governance.riskLevel == .restricted)
    }
}
