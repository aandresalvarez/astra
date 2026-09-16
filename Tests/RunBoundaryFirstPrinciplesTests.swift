import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// Regression cover for the class of failure where a run is terminated for
/// crossing a boundary ASTRA never told it about.
///
/// The originating incident: an Auto-mode task with the OS sandbox disabled was
/// stopped on its very first tool call — a `Read` of
/// `~/.claude/projects/<slug>/memory/MEMORY.md`, the provider's own memory
/// index. Three independent defects stacked:
///
/// 1. `AgentRuntimeHomeStateAccess` declares `~/.claude` provider-owned and the
///    OS-sandbox tier honours it, but `AgentRuntimePolicyGuard` had never heard
///    of it — and those two tiers are inversely activated.
/// 2. An out-of-boundary *read* was a terminal violation, even though the read
///    had already completed and no provider render expresses a read boundary.
/// 3. A one-run approval carried `permissionPolicyOverride: .restricted`, which
///    demoted the Auto run and switched the brokered tier back on.
///
/// Defect 3 is covered by `TaskPolicyPrecedenceTests`; 1 and 2 live here.
@Suite("Run boundary first principles")
struct RunBoundaryFirstPrinciplesTests {
    private static let home = "/Users/astra-run-boundary-fixture"
    private static let workspace = "/tmp/astra-run-boundary-workspace"
    private static let outsidePath = "/Users/astra-run-boundary-fixture/Documents/unrelated/notes.md"

    private static func manifest(
        runtime: AgentRuntimeID = .claudeCode,
        workspacePath: String = workspace,
        additionalPaths: [String] = [],
        additionalReadOnlyPaths: [String] = []
    ) -> RunPermissionManifest {
        // The incident shape: Auto policy, OS sandbox off, so the brokered guard
        // is the only tier scoping paths.
        let render = ProviderPolicyRender(
            providerID: runtime,
            adapterVersion: 1,
            policyLevel: .autonomous,
            configOwnership: .generated,
            permissionMode: .autonomous,
            allowedTools: ["Read", "Grep", "Glob", "Write", "Edit", "Bash"],
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        return RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "test",
            providerID: runtime,
            providerVersion: nil,
            model: "test-model",
            policyLevel: .autonomous,
            policyScope: .taskOverride,
            providerRender: render,
            workspacePath: workspacePath,
            additionalPaths: additionalPaths,
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            additionalReadOnlyPaths: additionalReadOnlyPaths
        )
    }

    private static func policyGuard(_ manifest: RunPermissionManifest) -> AgentRuntimePolicyGuard {
        AgentRuntimePolicyGuard(manifest: manifest, homeDirectories: [home])
    }

    private static func read(_ path: String, tool: String = "Read") -> ParsedEvent {
        .toolUse(name: tool, id: "tool-1", input: ["file_path": path])
    }

    // MARK: - Provider-private state is not out-of-bounds task data

    @Test("The provider's own home state is inside the brokered run boundary")
    func providerHomeStateIsInsideTheBoundary() {
        let boundary = RunBoundary(manifest: Self.manifest(), homeDirectories: [Self.home])

        #expect(boundary.isReadable("\(Self.home)/.claude/projects/slug/memory/MEMORY.md"))
        #expect(boundary.isProviderState("\(Self.home)/.claude/settings.json"))
        // The sandbox tier already grants the provider write access to its own
        // state; the brokered tier must not disagree with it.
        #expect(boundary.isWritable("\(Self.home)/.claude.json"))
        // Provider state is not a workspace root, so it must not sprout a task
        // output folder.
        #expect(!boundary.taskOutputRoots.contains { $0.hasPrefix(Self.home) })
        // Another account's provider state is still outside.
        #expect(!boundary.isReadable("/Users/someone-else/.claude/settings.json"))
        // And the home directory itself is not wholesale readable.
        #expect(!boundary.isReadable("\(Self.home)/.ssh/id_ed25519"))
    }

    @Test("Reading the provider's own memory index does not violate policy")
    func providerMemoryIndexReadIsAllowed() {
        let path = "\(Self.home)/.claude/projects/slug/memory/MEMORY.md"

        #expect(Self.policyGuard(Self.manifest()).violation(for: Self.read(path)) == nil)
    }

    @Test("Every runtime's declared home state reaches the brokered boundary")
    func everyRuntimeHomeStateReachesTheBoundary() {
        // The tier-consistency check: whatever `AgentRuntimeHomeStateAccess`
        // declares (and `ExecutionSandbox.providerStateRoots` grants) must also
        // be visible to the guard. State declared in only one tier is exactly
        // the drift this suite exists to prevent.
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let access = AgentRuntimeAdapterRegistry.homeStateAccess(for: runtime)
            guard !access.inheritedHomeWritableRelativePaths.isEmpty else { continue }
            let boundary = RunBoundary(
                manifest: Self.manifest(runtime: runtime),
                homeDirectories: [Self.home]
            )
            for relative in access.inheritedHomeWritableRelativePaths {
                let path = (Self.home as NSString).appendingPathComponent(relative)
                #expect(
                    boundary.isReadable(path),
                    "\(runtime.rawValue) declares \(relative) as provider state but the run boundary cannot read it"
                )
                #expect(
                    boundary.isWritable(path),
                    "\(runtime.rawValue) declares \(relative) as provider state but the run boundary cannot write it"
                )
            }
        }
    }

    // MARK: - A denial is a tool result, not a process death

    @Test("An out-of-boundary read is approvable, not fatal")
    func outOfBoundaryReadIsApprovable() throws {
        let violation = try #require(
            Self.policyGuard(Self.manifest()).violation(for: Self.read(Self.outsidePath))
        )

        #expect(violation.requiresApproval)
        #expect(violation.violationCategory == "out_of_boundary_read")
        #expect(violation.permissionRequest == .sandboxPath(
            path: Self.outsidePath,
            access: "read",
            toolName: "Read"
        ))
        // The approval must produce a grant the retry can actually consume:
        // `.sandboxPath` read grants flow through `TaskLaunchResourceResolver`
        // back into `additionalReadOnlyPaths`.
        #expect(violation.approvalGrants.contains(.sandboxPath(path: Self.outsidePath, access: "read")))
    }

    @Test("An out-of-boundary write is still a terminal violation")
    func outOfBoundaryWriteStaysTerminal() throws {
        let violation = try #require(
            Self.policyGuard(Self.manifest()).violation(for: .toolUse(
                name: "Write",
                id: "tool-1",
                input: ["file_path": Self.outsidePath, "content": "x"]
            ))
        )

        #expect(!violation.requiresApproval)
        #expect(violation.violationCategory == "runtime_policy")
    }

    @Test("An approved read path widens the boundary on the retry")
    func approvedReadPathWidensTheBoundary() {
        let retry = Self.manifest(additionalReadOnlyPaths: [Self.outsidePath])

        #expect(Self.policyGuard(retry).violation(for: Self.read(Self.outsidePath)) == nil)
        // Widening the *read* scope must not hand back write authority.
        #expect(Self.policyGuard(retry).violation(for: .toolUse(
            name: "Write",
            id: "tool-1",
            input: ["file_path": Self.outsidePath, "content": "x"]
        )) != nil)
    }

    // MARK: - One boundary, evaluated once

    @Test("The live classifier and the post-hoc guard judge the same input")
    func liveAndPostHocEvaluationsAgree() {
        let policyGuard = Self.policyGuard(Self.manifest())
        let cases: [(String, String, AgentRuntimePolicyGuard.CommandDisposition)] = [
            ("Read", "\(Self.home)/.claude/settings.json", .allowed),
            ("Read", "\(Self.workspace)/README.md", .allowed),
            ("Read", Self.outsidePath, .ask)
        ]

        for (tool, path, expected) in cases {
            let disposition = policyGuard.disposition(toolName: tool, command: nil, path: path)
            #expect(disposition == expected, "\(tool) \(path) classified as \(disposition)")

            let violation = policyGuard.violation(for: Self.read(path, tool: tool))
            switch expected {
            case .allowed:
                #expect(violation == nil, "\(tool) \(path) flagged post-hoc but allowed live")
            case .ask:
                #expect(violation?.requiresApproval == true)
            case .denied:
                #expect(violation != nil && violation?.requiresApproval == false)
            }
        }
    }

    @Test("A path-carrying ask is no longer classified as a bare tool name")
    func pathlessClassificationWouldHaveMissedTheBoundary() {
        let policyGuard = Self.policyGuard(Self.manifest())

        // Without the path the classifier sees only "Read", which an Auto policy
        // allows outright — the drift that let a live ask be waved through and
        // then flagged from the stream a moment later.
        #expect(policyGuard.disposition(toolName: "Read", command: nil) == .allowed)
        #expect(policyGuard.disposition(toolName: "Read", command: nil, path: Self.outsidePath) == .ask)
    }

    @Test("Claude control requests carry the file path into policy matching")
    func controlRequestExposesPathText() throws {
        let line = """
        {"type":"control_request","request_id":"req-1","request":\
        {"subtype":"can_use_tool","tool_name":"Read","input":{"file_path":"/tmp/x/y.md"}}}
        """
        let control = try #require(ClaudeControlProtocol.controlRequest(from: line))

        #expect(control.pathText == "/tmp/x/y.md")
        #expect(control.commandText == nil)
    }
}
