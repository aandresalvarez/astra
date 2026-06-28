import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("ASTRA Pack Manifest Validator")
struct AstraPackManifestValidatorTests {
    @Test("validator rejects empty pack ID")
    func validatorRejectsEmptyPackID() {
        var manifest = Self.validManifest()
        manifest.id = "   "

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.emptyPackID))
    }

    @Test("validator rejects unsupported core API version")
    func validatorRejectsUnsupportedCoreAPIVersion() {
        var manifest = Self.validManifest()
        manifest.coreAPIVersion = "2.0"

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.unsupportedCoreAPIVersion))
    }

    @Test("validator rejects policy widening")
    func validatorRejectsPolicyWidening() {
        var manifest = Self.validManifest()
        manifest.policyRestrictions = [
            AstraPackPolicyRestriction(
                id: "allow-external-write",
                contributionKind: "workspaceApp",
                action: "github.pull_requests.write",
                effect: "allow"
            )
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.policyWidening))
    }

    @Test("validator rejects duplicate shelf defaults")
    func validatorRejectsDuplicateShelfDefaults() {
        var manifest = Self.validManifest()
        manifest.shelfDefaults = [
            AstraPackShelfDefault(id: "inbox", title: "Inbox", kind: "documents"),
            AstraPackShelfDefault(id: "inbox", title: "Duplicate Inbox", kind: "documents")
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.duplicateShelfID))
    }

    @Test("validator rejects empty root capability package ID")
    func validatorRejectsEmptyRootCapabilityPackageID() {
        var manifest = Self.validManifest()
        manifest.capabilityPackageIDs = ["builtin.github", "   "]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/capabilityPackageIDs/1"
                && $0.message.contains("Capability package ID")
        })
    }

    @Test("validator rejects empty shelf capability package ID")
    func validatorRejectsEmptyShelfCapabilityPackageID() {
        var manifest = Self.validManifest()
        manifest.shelfDefaults = [
            AstraPackShelfDefault(
                id: "inbox",
                title: "Inbox",
                kind: "documents",
                capabilityPackageIDs: ["   "]
            )
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/shelfDefaults/0/capabilityPackageIDs/0"
                && $0.message.contains("Capability package ID")
        })
    }

    @Test("validator rejects empty app template capability package ID")
    func validatorRejectsEmptyAppTemplateCapabilityPackageID() {
        var manifest = Self.validManifest()
        manifest.appTemplates = [
            AstraPackAppTemplate(
                id: "triage",
                name: "Triage",
                contributionKind: "workspaceApp",
                templateID: "triage",
                capabilityPackageIDs: ["builtin.github", ""]
            )
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/appTemplates/0/capabilityPackageIDs/1"
                && $0.message.contains("Capability package ID")
        })
    }

    @Test("validator rejects empty app template template ID")
    func validatorRejectsEmptyAppTemplateTemplateID() {
        var manifest = Self.validManifest()
        manifest.appTemplates = [
            AstraPackAppTemplate(
                id: "triage",
                name: "Triage",
                contributionKind: "workspaceApp",
                templateID: "   "
            )
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/appTemplates/0/templateID"
                && $0.message.contains("Template ID")
        })
    }

    @Test("validator rejects invalid ID references")
    func validatorRejectsInvalidIDReferences() {
        var manifest = Self.validManifest()
        manifest.capabilityPackageIDs = ["Builtin.GitHub"]
        manifest.shelfDefaults = [
            AstraPackShelfDefault(
                id: "inbox",
                title: "Inbox",
                kind: "documents",
                capabilityPackageIDs: ["builtin.github "]
            )
        ]
        manifest.appTemplates = [
            AstraPackAppTemplate(
                id: "triage",
                name: "Triage",
                contributionKind: "workspaceApp",
                templateID: "triage template",
                capabilityPackageIDs: ["builtin.github"]
            )
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.path == "/capabilityPackageIDs/0" })
        #expect(report.blockers.contains { $0.path == "/shelfDefaults/0/capabilityPackageIDs/0" })
        #expect(report.blockers.contains { $0.path == "/appTemplates/0/templateID" })
    }

    @Test("validator rejects unknown contribution kind")
    func validatorRejectsUnknownContributionKind() {
        var manifest = Self.validManifest()
        manifest.appTemplates = [
            AstraPackAppTemplate(
                id: "future-template",
                name: "Future Template",
                contributionKind: "futureContribution",
                templateID: "future-template"
            )
        ]

        let report = AstraPackManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.map(\.code).contains(.unknownContributionKind))
    }

    private static func validManifest() -> AstraPackManifest {
        AstraPackManifest(
            formatVersion: 1,
            id: "astra.pack.valid",
            name: "Valid Pack",
            version: "1.0.0",
            coreAPIVersion: "1.0",
            description: "A valid pack manifest.",
            capabilityPackageIDs: ["builtin.github"],
            shelfDefaults: [
                AstraPackShelfDefault(id: "inbox", title: "Inbox", kind: "documents")
            ],
            appTemplates: [
                AstraPackAppTemplate(
                    id: "triage",
                    name: "Triage",
                    contributionKind: "workspaceApp",
                    templateID: "triage"
                )
            ],
            policyRestrictions: [
                AstraPackPolicyRestriction(
                    id: "read-only",
                    contributionKind: "workspaceApp",
                    action: "github.pull_requests.read",
                    effect: "restrict"
                )
            ],
            vocabulary: ["pullRequest": "Pull Request"],
            branding: AstraPackBranding(
                accentColor: "#4267B2",
                iconSystemName: "shippingbox",
                displayName: "Valid Pack"
            )
        )
    }
}
