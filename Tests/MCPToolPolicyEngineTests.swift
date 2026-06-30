import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("MCP Tool Policy Engine")
struct MCPToolPolicyEngineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("read/write/destructive classifications enforce scopes and native approval")
    func classificationsEnforceScopesAndApproval() {
        let cases: [PolicyCase] = [
            PolicyCase(
                toolName: "docs.get",
                grantedScopes: [.googleDocsRead],
                nativeApproval: nil,
                expectedAllowed: true,
                expectedReason: nil
            ),
            PolicyCase(
                toolName: "docs.batchUpdate",
                grantedScopes: [.googleDocsRead, .googleDocsWrite],
                nativeApproval: .approved(reason: "user clicked native approval"),
                expectedAllowed: true,
                expectedReason: nil
            ),
            PolicyCase(
                toolName: "drive.files.delete",
                grantedScopes: [.googleDriveRead, .googleDriveWrite],
                nativeApproval: .approved(reason: "user clicked native approval"),
                expectedAllowed: true,
                expectedReason: nil
            ),
            PolicyCase(
                toolName: "docs.batchUpdate",
                grantedScopes: [.googleDocsRead],
                nativeApproval: .approved(reason: "user clicked native approval"),
                expectedAllowed: false,
                expectedReason: .missingScope
            ),
            PolicyCase(
                toolName: "docs.batchUpdate",
                grantedScopes: [.googleDocsRead, .googleDocsWrite],
                nativeApproval: nil,
                expectedAllowed: false,
                expectedReason: .nativeApprovalRequired
            ),
            PolicyCase(
                toolName: "drive.files.delete",
                grantedScopes: [.googleDriveRead, .googleDriveWrite],
                nativeApproval: nil,
                expectedAllowed: false,
                expectedReason: .nativeApprovalRequired
            )
        ]

        for policyCase in cases {
            let audit = RecordingMCPToolPolicyAuditSink()
            let decision = makeEngine(auditSink: audit).evaluate(
                request(toolName: policyCase.toolName,
                        grantedScopes: policyCase.grantedScopes,
                        nativeApproval: policyCase.nativeApproval)
            )
            #expect(decision.isAllowed == policyCase.expectedAllowed, "tool \(policyCase.toolName)")
            #expect(decision.denialReason == policyCase.expectedReason, "tool \(policyCase.toolName)")
            #expect(audit.records.last?.result == (policyCase.expectedAllowed ? "allowed" : "denied"))
            #expect(audit.records.last?.toolName == policyCase.toolName)
        }
    }

    @Test("workspace enablement and server allowlist are checked before a tool can run")
    func workspaceEnablementAndAllowlist() {
        let cases: [PolicyCase] = [
            PolicyCase(toolName: "docs.get", enabledPackageIDs: [], expectedAllowed: false, expectedReason: .workspaceNotEnabled),
            PolicyCase(toolName: "docs.get", packageApproved: false, expectedAllowed: false, expectedReason: .workspaceNotEnabled),
            PolicyCase(toolName: "calendar.events.list", expectedAllowed: false, expectedReason: .toolNotAllowed),
            PolicyCase(toolName: "drive.files.delete", expectedAllowed: false, expectedReason: .toolExcluded)
        ]

        for policyCase in cases {
            let decision = makeEngine().evaluate(
                request(
                    toolName: policyCase.toolName,
                    server: policyCase.expectedReason == .toolExcluded ? googleWorkspaceServer(excludedTools: ["drive.files.delete"]) : nil,
                    enabledPackageIDs: policyCase.enabledPackageIDs,
                    packageApproved: policyCase.packageApproved,
                    grantedScopes: [.googleDocsRead, .googleDriveRead, .googleDriveWrite],
                    nativeApproval: .approved(reason: "native approval")
                )
            )
            #expect(decision.isAllowed == policyCase.expectedAllowed, "tool \(policyCase.toolName)")
            #expect(decision.denialReason == policyCase.expectedReason, "tool \(policyCase.toolName)")
        }
    }

    @Test("native policy allowlists are case-insensitive ASTRA permission checks")
    func nativePolicyAllowlistsAreCaseInsensitive() {
        let decision = makeEngine().evaluate(
            request(
                toolName: " DOCS.GET ",
                server: googleWorkspaceServer(allowedTools: ["docs.get"]),
                grantedScopes: [.googleDocsRead]
            )
        )

        #expect(decision.isAllowed)
        #expect(decision.denialReason == nil)
    }

    @Test("unknown tools fail closed even when server wildcard allowlist would otherwise match")
    func unknownToolFailsClosed() {
        let server = googleWorkspaceServer(allowedTools: [], excludedTools: [])
        let decision = makeEngine().evaluate(
            request(
                toolName: "totally.newTool",
                server: server,
                grantedScopes: [.googleDocsRead, .googleDocsWrite],
                nativeApproval: .approved(reason: "native approval")
            )
        )
        #expect(!decision.isAllowed)
        #expect(decision.denialReason == .unclassifiedTool)
    }

    @Test("generated apps cannot auto-approve write or destructive MCP tools")
    func generatedAppsCannotAutoApproveWrites() {
        for toolName in ["docs.batchUpdate", "drive.files.delete"] {
            let decision = makeEngine().evaluate(
                request(
                    toolName: toolName,
                    caller: .generatedWorkspaceApp(appID: UUID()),
                    grantedScopes: [.googleDocsRead, .googleDocsWrite, .googleDriveRead, .googleDriveWrite],
                    nativeApproval: .approved(reason: "forged page approval")
                )
            )
            #expect(!decision.isAllowed, "tool \(toolName)")
            #expect(decision.denialReason == .generatedAppWriteRequiresNativeApproval)
        }
    }

    @Test("pack policy can raise read MCP tools to native approval")
    func packPolicyCanRaiseReadToolsToNativeApproval() {
        let packPolicy = AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [
                AstraPackManifest(
                    id: "astra.pack.regulated-docs",
                    name: "Regulated Docs",
                    version: "1.0.0",
                    coreAPIVersion: "1.0",
                    description: "Requires review for Google Docs reads.",
                    policyRestrictions: [
                        AstraPackPolicyRestriction(
                            id: "docs-read-consent",
                            contributionKind: "workspaceApp",
                            action: "requireExplicitConsent",
                            effect: "restrict",
                            targetMCPServerID: "google",
                            targetMCPToolName: "docs.get",
                            message: "Regulated docs reads require native approval."
                        )
                    ]
                )
            ])
        )
        let audit = RecordingMCPToolPolicyAuditSink()
        let engine = makeEngine(auditSink: audit)

        let denied = engine.evaluate(
            request(
                toolName: "docs.get",
                grantedScopes: [.googleDocsRead],
                nativeApproval: nil,
                packPolicyResolver: { _ in packPolicy }
            )
        )
        let allowed = engine.evaluate(
            request(
                toolName: "docs.get",
                grantedScopes: [.googleDocsRead],
                nativeApproval: .approved(reason: "native review"),
                packPolicyResolver: { _ in packPolicy }
            )
        )

        #expect(!denied.isAllowed)
        #expect(denied.denialReason == .packPolicyNativeApprovalRequired)
        #expect(denied.policyEvidence.contains { $0.restrictionID == "docs-read-consent" })
        #expect(allowed.isAllowed)
        #expect(allowed.policyEvidence.contains { $0.restrictionID == "docs-read-consent" })
        #expect(audit.records.first?.policyEvidence.contains("docs-read-consent") == true)
    }

    @Test("request pack policy gates MCP server resolution")
    func requestPackPolicyGatesMCPServerResolution() {
        let packPolicy = AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [
                AstraPackManifest(
                    id: "astra.pack.blocks-google-mcp",
                    name: "Blocks Google MCP",
                    version: "1.0.0",
                    coreAPIVersion: "1.0",
                    description: "Disables Google MCP at runtime.",
                    policyRestrictions: [
                        AstraPackPolicyRestriction(
                            id: "disable-google-mcp",
                            contributionKind: "capabilityPackage",
                            action: "disableCapability",
                            effect: "restrict",
                            targetID: "google-mcp",
                            message: "Google MCP is disabled for this profile."
                        )
                    ]
                )
            ])
        )

        let decision = makeEngine().evaluate(
            request(
                toolName: "docs.get",
                grantedScopes: [.googleDocsRead],
                packPolicy: packPolicy,
                packPolicyResolver: { _ in .empty }
            )
        )

        #expect(!decision.isAllowed)
        #expect(decision.denialReason == .workspaceNotEnabled)
    }

    @Test("rate limit denies the third call in the same window and records a denial audit")
    func rateLimitDeniesThirdCall() {
        let audit = RecordingMCPToolPolicyAuditSink()
        let limiter = MCPToolCallRateLimiter(maxPerWindow: 2, window: 60)
        let engine = makeEngine(rateLimiter: limiter, auditSink: audit)
        let workspace = Workspace(name: "Policy", primaryPath: "/tmp/policy")

        let first = engine.evaluate(request(toolName: "docs.get", workspace: workspace, grantedScopes: [.googleDocsRead], now: now))
        let second = engine.evaluate(request(toolName: "docs.get", workspace: workspace, grantedScopes: [.googleDocsRead], now: now.addingTimeInterval(1)))
        let third = engine.evaluate(request(toolName: "docs.get", workspace: workspace, grantedScopes: [.googleDocsRead], now: now.addingTimeInterval(2)))

        #expect(first.isAllowed)
        #expect(second.isAllowed)
        #expect(!third.isAllowed)
        #expect(third.denialReason == .rateLimited)
        #expect(audit.records.map(\.result) == ["allowed", "allowed", "denied"])
        #expect(audit.records.last?.denialReason == "rate_limited")
    }

    @Test("audit and denial paths do not log tokens or sensitive payload values")
    func auditDoesNotLeakSensitivePayloads() {
        let audit = RecordingMCPToolPolicyAuditSink()
        let decision = makeEngine(auditSink: audit).evaluate(
            request(
                toolName: "docs.batchUpdate",
                grantedScopes: [.googleDocsRead],
                nativeApproval: nil,
                arguments: [
                    "access_token": "ya29.secret-token-value",
                    "documentId": "doc-123",
                    "body": ["text": "confidential payload"]
                ]
            )
        )

        #expect(!decision.isAllowed)
        #expect(decision.denialReason == .missingScope)
        let renderedDecision = String(describing: decision)
        let renderedAudit = audit.records.map { String(describing: $0) }.joined(separator: "\n")
        for forbidden in ["ya29.secret-token-value", "confidential payload", "access_token", "documentId"] {
            #expect(!renderedDecision.contains(forbidden))
            #expect(!renderedAudit.contains(forbidden))
        }
    }

    @Test("gateway adapter evaluates policy before forwarding")
    func gatewayAdapterEvaluatesBeforeForwarding() async throws {
        let deniedForwarder = RecordingMCPToolForwarder()
        let deniedGateway = MCPToolPolicyGatewayAdapter(policyEngine: makeEngine(), forwarder: deniedForwarder)
        await #expect(throws: MCPToolPolicyGatewayError.self) {
            _ = try await deniedGateway.call(
                request(toolName: "docs.batchUpdate", grantedScopes: [.googleDocsRead], nativeApproval: nil)
            )
        }
        #expect(await deniedForwarder.forwardedToolNames.isEmpty)

        let allowedForwarder = RecordingMCPToolForwarder()
        let allowedGateway = MCPToolPolicyGatewayAdapter(policyEngine: makeEngine(), forwarder: allowedForwarder)
        let response = try await allowedGateway.call(
            request(toolName: "docs.get", grantedScopes: [.googleDocsRead])
        )
        #expect(response.summary == "forwarded docs.get")
        #expect(await allowedForwarder.forwardedToolNames == ["docs.get"])
    }

    private func makeEngine(
        rateLimiter: MCPToolCallRateLimiter = MCPToolCallRateLimiter(maxPerWindow: 100, window: 60),
        auditSink: MCPToolPolicyAuditSink = RecordingMCPToolPolicyAuditSink()
    ) -> MCPToolPolicyEngine {
        MCPToolPolicyEngine(
            registry: googleWorkspaceRegistry(),
            rateLimiter: rateLimiter,
            auditSink: auditSink
        )
    }

    private func request(
        toolName: String,
        workspace: Workspace? = nil,
        server: PluginMCPServer? = nil,
        enabledPackageIDs: [String] = ["google-mcp"],
        packageApproved: Bool = true,
        caller: MCPToolPolicyCaller = .nativeRuntime,
        grantedScopes: Set<MCPToolPolicyScope> = [],
        nativeApproval: MCPToolNativeApproval? = nil,
        packPolicy: PackResolvedPolicy? = nil,
        packPolicyResolver: (Workspace?) -> PackResolvedPolicy = { _ in .empty },
        now: Date? = nil,
        arguments: [String: AnySendable] = [:]
    ) -> MCPToolPolicyRequest {
        let workspace = workspace ?? Workspace(name: "Policy", primaryPath: "/tmp/policy")
        workspace.enabledCapabilityIDs = enabledPackageIDs
        var package = googleWorkspacePackage(server: server ?? googleWorkspaceServer())
        package.governance = packageApproved ? .builtInApproved(riskLevel: .medium) : .localDraft()
        return MCPToolPolicyRequest(
            workspace: workspace,
            packages: [package],
            approvalRecords: [],
            serverID: "google",
            toolName: toolName,
            caller: caller,
            grantedScopes: grantedScopes,
            nativeApproval: nativeApproval,
            packPolicy: packPolicy,
            packPolicyResolver: packPolicyResolver,
            now: now ?? self.now,
            arguments: arguments
        )
    }
}

private struct PolicyCase {
    var toolName: String
    var enabledPackageIDs: [String] = ["google-mcp"]
    var packageApproved: Bool = true
    var grantedScopes: Set<MCPToolPolicyScope> = []
    var nativeApproval: MCPToolNativeApproval?
    var expectedAllowed: Bool
    var expectedReason: MCPToolPolicyDenialReason?
}

private func googleWorkspaceRegistry() -> MCPToolClassificationRegistry {
    MCPToolClassificationRegistry(classifications: [
        MCPToolClassification(
            serverID: "google",
            toolName: "docs.get",
            access: .read,
            requiredScopes: [.googleDocsRead]
        ),
        MCPToolClassification(
            serverID: "google",
            toolName: "docs.batchUpdate",
            access: .write,
            requiredScopes: [.googleDocsRead, .googleDocsWrite]
        ),
        MCPToolClassification(
            serverID: "google",
            toolName: "drive.files.delete",
            access: .destructive,
            requiredScopes: [.googleDriveRead, .googleDriveWrite]
        )
    ])
}

private func googleWorkspacePackage(server: PluginMCPServer) -> PluginPackage {
    PluginPackage(
        id: "google-mcp",
        name: "Google Workspace MCP",
        icon: "doc",
        description: "Google Workspace MCP",
        author: "ASTRA",
        category: "Integrations",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [],
        mcpServers: [server],
        templates: [],
        governance: .builtInApproved(riskLevel: .medium)
    )
}

private func googleWorkspaceServer(
    allowedTools: [String] = ["docs.get", "docs.batchUpdate", "drive.files.delete"],
    excludedTools: [String] = []
) -> PluginMCPServer {
    PluginMCPServer(
        id: "google",
        displayName: "Google Workspace",
        transport: .http,
        url: URL(string: "https://mcp.google.example"),
        allowedTools: allowedTools,
        excludedTools: excludedTools,
        trustLevel: .medium
    )
}

private final class RecordingMCPToolPolicyAuditSink: MCPToolPolicyAuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [MCPToolPolicyAuditRecord] = []

    func record(_ record: MCPToolPolicyAuditRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }
}

private actor RecordingMCPToolForwarder: MCPToolForwarding {
    private(set) var forwardedToolNames: [String] = []

    func forward(_ request: MCPToolPolicyRequest) async throws -> MCPToolGatewayResponse {
        forwardedToolNames.append(request.toolName)
        return MCPToolGatewayResponse(summary: "forwarded \(request.toolName)")
    }
}
