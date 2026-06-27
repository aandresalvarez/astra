import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("MCP control-plane runtime binding service")
struct MCPControlPlaneRuntimeBindingServiceTests {
    @Test("readiness reports missing required refs as failures and optional refs as warnings")
    func readinessReportsMissingRefsByRequirement() {
        let metadata = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(
                    id: "google-primary",
                    providerID: "googleWorkspace",
                    purpose: "Primary Google Workspace OAuth account.",
                    required: true
                ),
                MCPAuthProfileRef(
                    id: "google-fallback",
                    providerID: "googleWorkspace",
                    purpose: "Optional fallback account.",
                    required: false
                )
            ],
            secretRefs: [
                MCPSecretRef(
                    id: "google-access-token",
                    purpose: "Short-lived OAuth access token.",
                    required: true
                ),
                MCPSecretRef(
                    id: "quota-project-api-key",
                    purpose: "Optional quota project API key.",
                    required: false
                )
            ],
            configRefs: [
                MCPConfigRef(
                    id: "google-hosted-domain",
                    purpose: "Hosted-domain policy filter.",
                    required: true
                ),
                MCPConfigRef(
                    id: "google-locale",
                    purpose: "Optional locale preference.",
                    required: false
                )
            ]
        )
        let service = MCPControlPlaneRuntimeBindingService(
            resolver: EmptyMCPControlPlaneRuntimeBindingResolver()
        )

        let readiness = service.readiness(for: metadata)

        #expect(readiness.status == .blocked)
        #expect(readiness.issues.contains(.missingRequiredAuthProfile(refID: "google-primary", providerID: "googleWorkspace")))
        #expect(readiness.issues.contains(.missingOptionalAuthProfile(refID: "google-fallback", providerID: "googleWorkspace")))
        #expect(readiness.issues.contains(.missingRequiredSecret(refID: "google-access-token")))
        #expect(readiness.issues.contains(.missingOptionalSecret(refID: "quota-project-api-key")))
        #expect(readiness.issues.contains(.missingRequiredConfig(refID: "google-hosted-domain")))
        #expect(readiness.issues.contains(.missingOptionalConfig(refID: "google-locale")))
        #expect(readiness.issues.filter { $0.severity == .failure }.count == 3)
        #expect(readiness.issues.filter { $0.severity == .warning }.count == 3)
    }

    @Test("empty declared refs rely on invariant issues instead of duplicate missing-ref issues")
    func emptyDeclaredRefsDoNotEmitDuplicateMissingRefIssues() {
        let metadata = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(id: " ", providerID: " ", purpose: "Broken OAuth account.")
            ],
            secretRefs: [
                MCPSecretRef(id: "\n", purpose: "Broken secret.")
            ],
            configRefs: [
                MCPConfigRef(id: "\t", purpose: "Broken config.")
            ]
        )

        let readiness = MCPControlPlaneRuntimeBindingService(
            resolver: EmptyMCPControlPlaneRuntimeBindingResolver()
        ).readiness(for: metadata)

        #expect(readiness.status == .blocked)
        #expect(!readiness.issues.contains(.missingRequiredAuthProfile(refID: "", providerID: "")))
        #expect(!readiness.issues.contains(.missingRequiredSecret(refID: "")))
        #expect(!readiness.issues.contains(.missingRequiredConfig(refID: "")))
        #expect(readiness.issues.contains(.invalidControlPlane(reason: "auth profile ref ID is required")))
        #expect(readiness.issues.contains(.invalidControlPlane(
            reason: "auth profile <empty> is missing a provider ID"
        )))
        #expect(readiness.issues.contains(.invalidControlPlane(reason: "secret ref ID is required")))
        #expect(readiness.issues.contains(.invalidControlPlane(reason: "config ref ID is required")))
    }

    @Test("empty declared refs cannot populate empty-key resolved handles")
    func emptyDeclaredRefsDoNotPopulateResolvedHandles() throws {
        let metadata = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(id: " ", providerID: " ", purpose: "Broken OAuth account.")
            ],
            secretRefs: [
                MCPSecretRef(id: "\n", purpose: "Broken secret.")
            ],
            configRefs: [
                MCPConfigRef(id: "\t", purpose: "Broken config.")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "broken-auth",
                    destination: .environment,
                    name: "BROKEN_AUTH",
                    template: [.reference(.authProfile(" "))]
                ),
                MCPRuntimeBindingTemplate(
                    id: "broken-secret",
                    destination: .environment,
                    name: "BROKEN_SECRET",
                    template: [.reference(.secret("\n"))]
                ),
                MCPRuntimeBindingTemplate(
                    id: "broken-config",
                    destination: .environment,
                    name: "BROKEN_CONFIG",
                    template: [.reference(.config("\t"))]
                )
            ]
        )

        let readiness = MCPControlPlaneRuntimeBindingService(
            resolver: PermissiveEmptyIDRuntimeBindingResolver()
        ).readiness(for: metadata)

        let authPreview = try #require(readiness.bindingPreviews.first { $0.id == "broken-auth" })
        let secretPreview = try #require(readiness.bindingPreviews.first { $0.id == "broken-secret" })
        let configPreview = try #require(readiness.bindingPreviews.first { $0.id == "broken-config" })
        #expect(authPreview.redactedValue == "[missing-authProfile:]")
        #expect(secretPreview.redactedValue == "[missing-secret:]")
        #expect(configPreview.redactedValue == "[missing-config:]")
    }

    @Test("resolved binding previews redact auth secret and config handles")
    func resolvedBindingPreviewsAreRedacted() throws {
        let secretStore = MockSecretStore()
        secretStore.save(
            key: "GOOGLE_ACCESS_TOKEN",
            value: "ya29.raw-access-token-that-must-not-leak",
            entityID: "astra-dev-google-oauth-profile-1",
            label: nil
        )
        let resolver = SecretStoreMCPControlPlaneRuntimeBindingResolver(
            secretStore: secretStore,
            authProfileHandles: [
                MCPControlPlaneAuthProfileHandle(
                    refID: "google-primary",
                    providerID: "googleWorkspace",
                    profileID: "google-oauth-profile-1",
                    displayName: "Alvaro Example"
                )
            ],
            secretHandles: [
                MCPControlPlaneSecretHandle(
                    refID: "google-access-token",
                    entityID: "astra-dev-google-oauth-profile-1",
                    key: "GOOGLE_ACCESS_TOKEN",
                    label: "Google Workspace access token"
                )
            ],
            configHandles: [
                MCPControlPlaneConfigHandle(
                    refID: "google-hosted-domain",
                    sourceID: "google-workspace-domain",
                    displayName: "Hosted domain"
                )
            ]
        )
        let service = MCPControlPlaneRuntimeBindingService(resolver: resolver)
        let metadata = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(
                    id: "google-primary",
                    providerID: "googleWorkspace",
                    purpose: "Google Workspace OAuth account."
                )
            ],
            secretRefs: [
                MCPSecretRef(
                    id: "google-access-token",
                    purpose: "Short-lived OAuth access token."
                )
            ],
            configRefs: [
                MCPConfigRef(
                    id: "google-hosted-domain",
                    purpose: "Hosted-domain policy filter."
                )
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "authorization-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .literal("Bearer "),
                        .reference(.secret("google-access-token"))
                    ]
                ),
                MCPRuntimeBindingTemplate(
                    id: "account-env",
                    destination: .environment,
                    name: "GOOGLE_WORKSPACE_ACCOUNT",
                    template: [
                        .reference(.authProfile("google-primary"))
                    ]
                ),
                MCPRuntimeBindingTemplate(
                    id: "domain-env",
                    destination: .environment,
                    name: "GOOGLE_WORKSPACE_DOMAIN",
                    template: [
                        .reference(.config("google-hosted-domain"))
                    ]
                )
            ]
        )

        let readiness = service.readiness(for: metadata)

        #expect(readiness.status == .ready)
        #expect(readiness.issues.isEmpty)
        let authz = try #require(readiness.bindingPreviews.first { $0.id == "authorization-header" })
        let account = try #require(readiness.bindingPreviews.first { $0.id == "account-env" })
        let domain = try #require(readiness.bindingPreviews.first { $0.id == "domain-env" })
        #expect(authz.redactedValue == "Bearer [secret:google-access-token]")
        #expect(account.redactedValue == "[authProfile:google-primary]")
        #expect(domain.redactedValue == "[config:google-hosted-domain]")
        let allPreviewsReady = readiness.bindingPreviews.allSatisfy { $0.isReady }
        #expect(allPreviewsReady)

        let previewJSON = String(decoding: try JSONEncoder().encode(readiness.bindingPreviews), as: UTF8.self)
        #expect(previewJSON.contains("google-access-token"))
        #expect(!previewJSON.contains("ya29.raw-access-token-that-must-not-leak"))
        #expect(!previewJSON.localizedCaseInsensitiveContains("raw-access-token"))
    }

    @Test("unresolved binding references block aggregate readiness")
    func unresolvedBindingReferencesBlockAggregateReadiness() throws {
        let metadata = MCPControlPlaneMetadata(
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "authorization-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .literal("Bearer "),
                        .reference(.secret("undeclared-token"))
                    ]
                )
            ]
        )
        let service = MCPControlPlaneRuntimeBindingService(
            resolver: EmptyMCPControlPlaneRuntimeBindingResolver()
        )

        let readiness = service.readiness(for: metadata)
        let preview = try #require(readiness.bindingPreviews.first)

        #expect(readiness.status == .blocked)
        #expect(readiness.issues.contains(.invalidRuntimeBinding(bindingID: "authorization-header")))
        #expect(!preview.isReady)
        #expect(preview.redactedValue == "Bearer [missing-secret:undeclared-token]")
    }

    @Test("binding invariant violations block aggregate readiness")
    func bindingInvariantViolationsBlockAggregateReadiness() throws {
        let secretStore = MockSecretStore()
        secretStore.save(
            key: "GOOGLE_ACCESS_TOKEN",
            value: "ya29.raw-access-token-that-must-not-leak",
            entityID: "astra-dev-google-oauth-profile-1",
            label: nil
        )
        let resolver = SecretStoreMCPControlPlaneRuntimeBindingResolver(
            secretStore: secretStore,
            secretHandles: [
                MCPControlPlaneSecretHandle(
                    refID: "google-access-token",
                    entityID: "astra-dev-google-oauth-profile-1",
                    key: "GOOGLE_ACCESS_TOKEN"
                )
            ]
        )
        let metadata = MCPControlPlaneMetadata(
            secretRefs: [
                MCPSecretRef(id: "google-access-token", purpose: "Short-lived OAuth access token.")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "invalid-literal",
                    destination: .environment,
                    name: "GOOGLE_LABEL",
                    template: [
                        MCPRuntimeTemplateSegment(
                            kind: .literal,
                            literal: "safe-label",
                            reference: .secret("google-access-token")
                        )
                    ]
                ),
                MCPRuntimeBindingTemplate(
                    id: "empty-template",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: []
                )
            ]
        )

        let readiness = MCPControlPlaneRuntimeBindingService(resolver: resolver)
            .readiness(for: metadata)

        #expect(readiness.status == .blocked)
        #expect(readiness.issues.contains(.invalidRuntimeBinding(bindingID: "invalid-literal")))
        #expect(readiness.issues.contains(.invalidRuntimeBinding(bindingID: "empty-template")))
        let invalidLiteral = try #require(readiness.bindingPreviews.first { $0.id == "invalid-literal" })
        let emptyTemplate = try #require(readiness.bindingPreviews.first { $0.id == "empty-template" })
        #expect(!invalidLiteral.isReady)
        #expect(!emptyTemplate.isReady)
    }

    @Test("duplicate binding IDs block aggregate readiness")
    func duplicateBindingIDsBlockAggregateReadiness() {
        let metadata = MCPControlPlaneMetadata(
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "duplicate",
                    destination: .environment,
                    name: "ONE",
                    template: [.literal("one")]
                ),
                MCPRuntimeBindingTemplate(
                    id: " duplicate ",
                    destination: .environment,
                    name: "TWO",
                    template: [.literal("two")]
                )
            ]
        )

        let readiness = MCPControlPlaneRuntimeBindingService(
            resolver: EmptyMCPControlPlaneRuntimeBindingResolver()
        ).readiness(for: metadata)

        #expect(readiness.status == .blocked)
        #expect(readiness.issues.contains(.invalidRuntimeBinding(bindingID: "duplicate")))
    }

    @Test("empty runtime binding ID reports control-plane issue instead of blank binding issue")
    func emptyRuntimeBindingIDReportsControlPlaneIssueInsteadOfBlankBindingIssue() throws {
        let metadata = MCPControlPlaneMetadata(
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: " ",
                    destination: .environment,
                    name: "BROKEN_BINDING",
                    template: [.literal("safe-label")]
                )
            ]
        )

        let readiness = MCPControlPlaneRuntimeBindingService(
            resolver: EmptyMCPControlPlaneRuntimeBindingResolver()
        ).readiness(for: metadata)
        let preview = try #require(readiness.bindingPreviews.first)

        #expect(readiness.status == .blocked)
        #expect(!readiness.issues.contains(.invalidRuntimeBinding(bindingID: "")))
        #expect(readiness.issues.contains(.invalidControlPlane(
            reason: "runtime binding <empty> is invalid: runtime binding ID is required"
        )))
        #expect(preview.id.isEmpty)
        #expect(!preview.isReady)
    }

    @Test("package JSON and binding preview serialization keep raw secret values out of durable surfaces")
    func packageAndPreviewSerializationKeepRawSecretsOut() throws {
        let rawAccessToken = "ya29.raw-access-token-that-must-not-leak"
        let rawRefreshToken = "1//raw-refresh-token-that-must-not-leak"
        let rawAPIKey = "AIza-raw-api-key-that-must-not-leak"
        let secretStore = MockSecretStore()
        secretStore.save(
            key: "GOOGLE_ACCESS_TOKEN",
            value: rawAccessToken,
            entityID: "astra-dev-google-oauth-profile-1",
            label: nil
        )
        let resolver = SecretStoreMCPControlPlaneRuntimeBindingResolver(
            secretStore: secretStore,
            authProfileHandles: [
                MCPControlPlaneAuthProfileHandle(
                    refID: "google-primary",
                    providerID: "googleWorkspace",
                    profileID: "google-oauth-profile-1",
                    displayName: "Alvaro Example"
                )
            ],
            secretHandles: [
                MCPControlPlaneSecretHandle(
                    refID: "google-access-token",
                    entityID: "astra-dev-google-oauth-profile-1",
                    key: "GOOGLE_ACCESS_TOKEN",
                    label: "Google Workspace access token"
                )
            ],
            configHandles: [
                MCPControlPlaneConfigHandle(
                    refID: "google-hosted-domain",
                    sourceID: "google-workspace-domain",
                    displayName: "Hosted domain"
                )
            ]
        )
        let controlPlane = MCPControlPlaneMetadata(
            authProfileRefs: [
                MCPAuthProfileRef(
                    id: "google-primary",
                    providerID: "googleWorkspace",
                    purpose: "Google Workspace OAuth account."
                )
            ],
            secretRefs: [
                MCPSecretRef(
                    id: "google-access-token",
                    purpose: "Short-lived OAuth access token."
                )
            ],
            configRefs: [
                MCPConfigRef(
                    id: "google-hosted-domain",
                    purpose: "Hosted-domain policy filter."
                )
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "authorization-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .literal("Bearer "),
                        .reference(.secret("google-access-token"))
                    ]
                )
            ]
        )
        let package = PluginPackage(
            id: "google-workspace-remote-mcp",
            name: "Google Workspace Remote MCP",
            icon: "link",
            description: "Google Workspace remote MCP routed through ASTRA.",
            author: "ASTRA",
            category: "Productivity",
            tags: ["mcp", "google"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "google-workspace",
                    displayName: "Google Workspace",
                    transport: .http,
                    url: URL(string: "https://mcp.astra.local/google-workspace"),
                    trustLevel: .high,
                    controlPlane: controlPlane
                )
            ],
            templates: []
        )

        let packageJSON = String(decoding: try JSONEncoder().encode(package), as: UTF8.self)
        let readiness = MCPControlPlaneRuntimeBindingService(resolver: resolver)
            .readiness(for: controlPlane)
        let previewJSON = String(decoding: try JSONEncoder().encode(readiness.bindingPreviews), as: UTF8.self)

        for secret in [rawAccessToken, rawRefreshToken, rawAPIKey] {
            #expect(!packageJSON.contains(secret))
            #expect(!previewJSON.contains(secret))
        }
        #expect(packageJSON.contains("google-access-token"))
        #expect(previewJSON.contains("[secret:google-access-token]"))
        #expect(readiness.status == .ready)
    }
}

private struct EmptyMCPControlPlaneRuntimeBindingResolver: MCPControlPlaneRuntimeBindingResolver {
    func authProfileHandle(for ref: MCPAuthProfileRef) -> MCPControlPlaneAuthProfileHandle? {
        nil
    }

    func secretHandle(for ref: MCPSecretRef) -> MCPControlPlaneSecretHandle? {
        nil
    }

    func configHandle(for ref: MCPConfigRef) -> MCPControlPlaneConfigHandle? {
        nil
    }
}

private struct PermissiveEmptyIDRuntimeBindingResolver: MCPControlPlaneRuntimeBindingResolver {
    func authProfileHandle(for ref: MCPAuthProfileRef) -> MCPControlPlaneAuthProfileHandle? {
        MCPControlPlaneAuthProfileHandle(
            refID: ref.id,
            providerID: ref.providerID,
            profileID: "profile-id"
        )
    }

    func secretHandle(for ref: MCPSecretRef) -> MCPControlPlaneSecretHandle? {
        MCPControlPlaneSecretHandle(
            refID: ref.id,
            entityID: "entity-id",
            key: "SECRET_KEY"
        )
    }

    func configHandle(for ref: MCPConfigRef) -> MCPControlPlaneConfigHandle? {
        MCPControlPlaneConfigHandle(
            refID: ref.id,
            sourceID: "config-source-id"
        )
    }
}
