import Foundation
import Testing
import ASTRACore

@Suite("ASTRA Pack Manifest")
struct AstraPackManifestTests {
    @Test("pack manifest round trips core fields")
    func packManifestRoundTripsCoreFields() throws {
        let manifest = AstraPackManifest(
            formatVersion: 1,
            id: "astra.pack.research",
            name: "Research Pack",
            version: "1.2.3",
            coreAPIVersion: "1.0",
            description: "Focused research workflows.",
            capabilityPackageIDs: ["builtin.google-workspace", "builtin.github"],
            shelfDefaults: [
                AstraPackShelfDefault(
                    id: "literature",
                    title: "Literature",
                    kind: "documents",
                    capabilityPackageIDs: ["builtin.google-workspace"]
                )
            ],
            appTemplates: [
                AstraPackAppTemplate(
                    id: "review-board",
                    name: "Review Board",
                    contributionKind: "workspaceApp",
                    templateID: "review-board-template",
                    capabilityPackageIDs: ["builtin.github"]
                )
            ],
            policyRestrictions: [
                AstraPackPolicyRestriction(
                    id: "read-only-github",
                    contributionKind: "workspaceApp",
                    action: "github.pull_requests.read",
                    effect: "restrict"
                )
            ],
            vocabulary: [
                "review": "Review",
                "workspace": "Workspace"
            ],
            branding: AstraPackBranding(
                accentColor: "#4267B2",
                iconSystemName: "shippingbox",
                displayName: "ASTRA Research"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(AstraPackManifest.self, from: data)
        let encodedAgain = try encoder.encode(decoded)

        #expect(decoded == manifest)
        #expect(String(data: encodedAgain, encoding: .utf8) == String(data: data, encoding: .utf8))
    }

    @Test("pack manifest defaults optional collections to empty")
    func packManifestDefaultsOptionalCollectionsToEmpty() throws {
        let json = """
        {
          "formatVersion": 1,
          "id": "astra.pack.minimal",
          "name": "Minimal Pack",
          "version": "1.0.0",
          "coreAPIVersion": "1.0",
          "description": "Smallest useful manifest."
        }
        """

        let manifest = try JSONDecoder().decode(AstraPackManifest.self, from: Data(json.utf8))

        #expect(manifest.capabilityPackageIDs.isEmpty)
        #expect(manifest.shelfDefaults.isEmpty)
        #expect(manifest.appTemplates.isEmpty)
        #expect(manifest.policyRestrictions.isEmpty)
        #expect(manifest.vocabulary.isEmpty)
        #expect(manifest.branding == nil)
    }

    @Test("pack manifest rejects unknown future required format")
    func packManifestRejectsUnknownFutureRequiredFormat() {
        let json = """
        {
          "formatVersion": 2,
          "id": "astra.pack.future",
          "name": "Future Pack",
          "version": "1.0.0",
          "coreAPIVersion": "1.0",
          "description": "Requires a future format."
        }
        """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AstraPackManifest.self, from: Data(json.utf8))
        }
    }

    @Test("pack manifest rejects unsupported past format")
    func packManifestRejectsUnsupportedPastFormat() {
        let json = """
        {
          "formatVersion": 0,
          "id": "astra.pack.zero-format",
          "name": "Zero Format Pack",
          "version": "1.0.0",
          "coreAPIVersion": "1.0",
          "description": "Requires the current format."
        }
        """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AstraPackManifest.self, from: Data(json.utf8))
        }
    }

    @Test("pack manifest rejects missing format version")
    func packManifestRejectsMissingFormatVersion() {
        let json = """
        {
          "id": "astra.pack.missing-format",
          "name": "Missing Format Pack",
          "version": "1.0.0",
          "coreAPIVersion": "1.0",
          "description": "Missing required formatVersion."
        }
        """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AstraPackManifest.self, from: Data(json.utf8))
        }
    }
}
