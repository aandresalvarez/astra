import Foundation
import Testing
import ASTRACore

@Suite("MCP control plane contracts")
struct MCPControlPlaneContractTests {
    @Test("MCP server control-plane metadata round trips without secret values")
    func controlPlaneMetadataRoundTripsWithoutSecretValues() throws {
        let controlPlane = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(
                    id: "google-workspace-primary",
                    providerID: "googleWorkspace",
                    purpose: "ASTRA-owned OAuth account for Google Workspace MCP.",
                    required: true
                )
            ],
            secretRefs: [
                MCPSecretRef(
                    id: "google-workspace-access-token",
                    purpose: "Short-lived access token projected by ASTRA at the gateway boundary.",
                    required: true
                )
            ],
            configRefs: [
                MCPConfigRef(
                    id: "google-workspace-domain",
                    purpose: "Optional hosted-domain constraint for policy display.",
                    required: false
                )
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "google-workspace-authz",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .literal("Bearer "),
                        .reference(.secret("google-workspace-access-token"))
                    ]
                ),
                MCPRuntimeBindingTemplate(
                    id: "google-workspace-domain-env",
                    destination: .environment,
                    name: "GOOGLE_WORKSPACE_DOMAIN",
                    template: [
                        .reference(.config("google-workspace-domain"))
                    ]
                )
            ],
            providerCapabilities: [
                MCPProviderCapability(
                    id: "drive-files-read",
                    displayName: "Drive files read",
                    contractID: .googleWorkspaceDriveRead,
                    availability: .preview,
                    requiredAuthProfileRefs: ["google-workspace-primary"],
                    requiredSecretRefs: ["google-workspace-access-token"],
                    requiredConfigRefs: ["google-workspace-domain"],
                    requiredScopes: [
                        OAuthScope(
                            value: "https://www.googleapis.com/auth/drive.metadata.readonly",
                            purpose: "Read Drive metadata for generated app contract responses.",
                            sensitivity: .restricted
                        )
                    ],
                    supportedToolEffects: [.read]
                )
            ]
        )
        let server = PluginMCPServer(
            id: "google-workspace",
            displayName: "Google Workspace Remote MCP",
            transport: .http,
            url: URL(string: "https://mcp.astra.local/google-workspace"),
            allowedTools: ["drive.files.list"],
            trustLevel: .high,
            controlPlane: controlPlane
        )

        let data = try JSONEncoder().encode(server)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(PluginMCPServer.self, from: data)

        #expect(decoded.controlPlane == controlPlane)
        #expect(decoded.controlPlane?.runtimeBindings.first?.referencedSecretRefs == ["google-workspace-access-token"])
        #expect(decoded.controlPlane?.runtimeBindings.last?.referencedConfigRefs == ["google-workspace-domain"])
        #expect(decoded.controlPlane?.invariantViolations().isEmpty == true)
        #expect(json.contains("google-workspace-access-token"))
        #expect(!json.contains("ya29.secret-token-value"))
        #expect(!json.localizedCaseInsensitiveContains("refreshToken"))
        #expect(!json.localizedCaseInsensitiveContains("secretValue"))
    }

    @Test("runtime binding templates report undeclared secret config and auth refs")
    func runtimeBindingTemplatesReportUndeclaredRefs() {
        let controlPlane = MCPControlPlaneMetadata(
            authProfileRefs: [MCPAuthProfileRef(id: "declared-auth", providerID: "googleWorkspace", purpose: "Auth")],
            secretRefs: [MCPSecretRef(id: "declared-secret", purpose: "Token")],
            configRefs: [MCPConfigRef(id: "declared-config", purpose: "Domain")],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "bad-binding",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .reference(.secret("missing-secret")),
                        .reference(.config("missing-config")),
                        .reference(.authProfile("missing-auth"))
                    ]
                )
            ]
        )

        let violations = controlPlane.invariantViolations()

        #expect(violations.contains(.runtimeBinding("bad-binding", .undeclaredSecretRef("missing-secret"))))
        #expect(violations.contains(.runtimeBinding("bad-binding", .undeclaredConfigRef("missing-config"))))
        #expect(violations.contains(.runtimeBinding("bad-binding", .undeclaredAuthProfileRef("missing-auth"))))
    }

    @Test("runtime binding segments reject unused payload fields that could carry secret values")
    func runtimeBindingSegmentsRejectUnusedPayloadFields() {
        let controlPlane = MCPControlPlaneMetadata(
            secretRefs: [MCPSecretRef(id: "declared-secret", purpose: "Token")],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "bad-reference",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        MCPRuntimeTemplateSegment(
                            kind: .reference,
                            literal: "Bearer ya29.secret-token-value",
                            reference: .secret("declared-secret")
                        )
                    ]
                ),
                MCPRuntimeBindingTemplate(
                    id: "bad-literal",
                    destination: .environment,
                    name: "MCP_LABEL",
                    template: [
                        MCPRuntimeTemplateSegment(
                            kind: .literal,
                            literal: "safe-label",
                            reference: .secret("declared-secret")
                        )
                    ]
                )
            ]
        )

        let violations = controlPlane.invariantViolations()

        #expect(violations.contains(.runtimeBinding("bad-reference", .referenceSegmentMustNotCarryLiteral)))
        #expect(violations.contains(.runtimeBinding("bad-literal", .literalSegmentMustNotCarryReference)))
    }

    @Test("runtime binding reference lists drop empty reference IDs")
    func runtimeBindingReferenceListsDropEmptyReferenceIDs() {
        let binding = MCPRuntimeBindingTemplate(
            id: "empty-ref-binding",
            destination: .environment,
            name: "BROKEN_TOKEN",
            template: [
                .reference(.secret("   ")),
                .reference(.config("\n\t")),
                .reference(.authProfile("  ")),
                .reference(.secret(" declared-secret "))
            ]
        )

        let violations = binding.invariantViolations(
            declaredSecretRefs: ["declared-secret"],
            declaredConfigRefs: [],
            declaredAuthProfileRefs: []
        )

        #expect(violations.contains(.referenceIDRequired))
        #expect(binding.referencedSecretRefs == ["declared-secret"])
        #expect(binding.referencedConfigRefs.isEmpty)
        #expect(binding.referencedAuthProfileRefs.isEmpty)
    }

    @Test("provider capability required refs ignore blank IDs")
    func providerCapabilityRequiredRefsIgnoreBlankIDs() {
        let capability = MCPProviderCapability(
            id: "drive-files-read",
            displayName: "Drive files read",
            contractID: .googleWorkspaceDriveRead,
            availability: .preview,
            requiredAuthProfileRefs: [" declared-auth ", " "],
            requiredSecretRefs: ["\t"],
            requiredConfigRefs: [" declared-config ", ""]
        )

        let violations = capability.invariantViolations(
            declaredAuthProfileRefs: ["declared-auth"],
            declaredSecretRefs: [],
            declaredConfigRefs: ["declared-config"]
        )

        #expect(!violations.contains(.undeclaredAuthProfileRef("")))
        #expect(!violations.contains(.undeclaredSecretRef("")))
        #expect(!violations.contains(.undeclaredConfigRef("")))
        #expect(violations.isEmpty)
    }

    @Test("declared refs use canonical IDs and reject empty declarations")
    func declaredRefsUseCanonicalIDsAndRejectEmptyDeclarations() {
        let controlPlane = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(id: " declared-auth ", providerID: " googleWorkspace ", purpose: "Auth"),
                MCPAuthProfileRef(id: " ", providerID: " ", purpose: "Broken auth")
            ],
            secretRefs: [
                MCPSecretRef(id: " declared-secret ", purpose: "Token"),
                MCPSecretRef(id: "", purpose: "Broken secret")
            ],
            configRefs: [
                MCPConfigRef(id: " declared-config ", purpose: "Domain"),
                MCPConfigRef(id: "  ", purpose: "Broken config")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "trimmed-binding",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .reference(.authProfile(" declared-auth ")),
                        .reference(.secret(" declared-secret ")),
                        .reference(.config(" declared-config "))
                    ]
                )
            ],
            providerCapabilities: [
                MCPProviderCapability(
                    id: "drive-files-read",
                    displayName: "Drive files read",
                    contractID: .googleWorkspaceDriveRead,
                    availability: .preview,
                    requiredAuthProfileRefs: ["declared-auth"],
                    requiredSecretRefs: ["declared-secret"],
                    requiredConfigRefs: ["declared-config"]
                )
            ]
        )

        let violations = controlPlane.invariantViolations()

        #expect(violations.contains(.authProfileRefIDRequired))
        #expect(violations.contains(.authProfileProviderIDRequired("")))
        #expect(violations.contains(.secretRefIDRequired))
        #expect(violations.contains(.configRefIDRequired))
        #expect(!violations.contains(.runtimeBinding("trimmed-binding", .undeclaredAuthProfileRef("declared-auth"))))
        #expect(!violations.contains(.runtimeBinding("trimmed-binding", .undeclaredSecretRef("declared-secret"))))
        #expect(!violations.contains(.runtimeBinding("trimmed-binding", .undeclaredConfigRef("declared-config"))))
        #expect(!violations.contains(.providerCapability("drive-files-read", .undeclaredAuthProfileRef("declared-auth"))))
        #expect(!violations.contains(.providerCapability("drive-files-read", .undeclaredSecretRef("declared-secret"))))
        #expect(!violations.contains(.providerCapability("drive-files-read", .undeclaredConfigRef("declared-config"))))
        #expect(controlPlane.runtimeBindings.first?.referencedAuthProfileRefs == ["declared-auth"])
        #expect(controlPlane.runtimeBindings.first?.referencedSecretRefs == ["declared-secret"])
        #expect(controlPlane.runtimeBindings.first?.referencedConfigRefs == ["declared-config"])
    }

    @Test("control-plane metadata decodes secure defaults from sparse manifests")
    func controlPlaneMetadataDecodesSecureDefaultsFromSparseManifests() throws {
        let json = """
        {
          "runtimeBindings": [
            {
              "id": "domain-env",
              "destination": "environment",
              "name": "GOOGLE_WORKSPACE_DOMAIN",
              "template": [
                {
                  "kind": "reference",
                  "reference": {
                    "kind": "configRef",
                    "id": "google-workspace-domain"
                  }
                }
              ]
            }
          ],
          "providerCapabilities": [
            {
              "id": "drive-files-read",
              "displayName": "Drive files read",
              "contractID": "googleWorkspace.drive.read",
              "availability": "preview"
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(MCPControlPlaneMetadata.self, from: Data(json.utf8))

        #expect(decoded.authProfileRefs.isEmpty)
        #expect(decoded.secretRefs.isEmpty)
        #expect(decoded.configRefs.isEmpty)
        #expect(decoded.runtimeBindings.first?.logRedaction == .whenReferencesSensitive)
        #expect(decoded.providerCapabilities.first?.requiredAuthProfileRefs.isEmpty == true)
        #expect(decoded.providerCapabilities.first?.requiredSecretRefs.isEmpty == true)
        #expect(decoded.providerCapabilities.first?.requiredConfigRefs.isEmpty == true)
        #expect(decoded.providerCapabilities.first?.requiredScopes.isEmpty == true)
        #expect(decoded.providerCapabilities.first?.supportedToolEffects.isEmpty == true)
    }

    @Test("runtime delivery and validation drift evidence are stable Codable Equatable contracts")
    func runtimeDeliveryAndValidationDriftEvidenceRoundTrip() throws {
        let delivery = MCPRuntimeDeliveryEvidence(
            id: "delivery-1",
            serverID: "google-workspace",
            kind: .gatewayProjection,
            status: .delivered,
            observedAt: "2026-06-27T12:00:00Z",
            fingerprints: [
                MCPRuntimeEvidenceFingerprint(
                    subject: "provider-config",
                    algorithm: "sha256",
                    digest: "87f3"
                )
            ],
            diagnosticRefIDs: ["task-run-log:123"]
        )
        let drift = MCPValidationDriftEvidence(
            id: "drift-1",
            serverID: "google-workspace",
            kind: .scopeMismatch,
            severity: .blocking,
            expectedFingerprint: "expected-scope-set",
            observedFingerprint: "observed-scope-set",
            evidenceIDs: [delivery.id]
        )

        let encodedDelivery = try JSONEncoder().encode(delivery)
        let encodedDrift = try JSONEncoder().encode(drift)

        #expect(try JSONDecoder().decode(MCPRuntimeDeliveryEvidence.self, from: encodedDelivery) == delivery)
        #expect(try JSONDecoder().decode(MCPValidationDriftEvidence.self, from: encodedDrift) == drift)
        #expect(String(decoding: encodedDelivery, as: UTF8.self).contains("gatewayProjection"))
        #expect(String(decoding: encodedDrift, as: UTF8.self).contains("scopeMismatch"))
    }

    @Test("runtime evidence decodes sparse payloads with empty collection defaults")
    func runtimeEvidenceDecodesSparsePayloadsWithEmptyCollectionDefaults() throws {
        let deliveryJSON = """
        {
          "id": "delivery-1",
          "serverID": "google-workspace",
          "kind": "gatewayProjection",
          "status": "pending"
        }
        """
        let driftJSON = """
        {
          "id": "drift-1",
          "serverID": "google-workspace",
          "kind": "deliveryEvidenceStale",
          "severity": "warning"
        }
        """

        let delivery = try JSONDecoder().decode(MCPRuntimeDeliveryEvidence.self, from: Data(deliveryJSON.utf8))
        let drift = try JSONDecoder().decode(MCPValidationDriftEvidence.self, from: Data(driftJSON.utf8))

        #expect(delivery.observedAt == nil)
        #expect(delivery.fingerprints.isEmpty)
        #expect(delivery.diagnosticRefIDs.isEmpty)
        #expect(drift.expectedFingerprint == nil)
        #expect(drift.observedFingerprint == nil)
        #expect(drift.evidenceIDs.isEmpty)
    }
}
