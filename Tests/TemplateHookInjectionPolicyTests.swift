import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Template hooks follow the runtime that reads them")
@MainActor
struct TemplateHookInjectionPolicyTests {
    private static let hooks = #"{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}"#
    private static let otherRuntimes: [AgentRuntimeID] = [.codexCLI, .copilotCLI, .cursorCLI, .antigravityCLI, .openCodeCLI]

    private func makeCheckout() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-hook-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func settingsPath(_ checkout: String) -> String {
        ClaudeSettingsStore.settingsPath(for: checkout)
    }

    private func task(_ runtime: AgentRuntimeID, in checkout: String, readOnly: Bool = true) -> AgentTask {
        let task = AgentTask(
            title: "Summarize the release notes",
            goal: "Explain the differences between the two releases.",
            workspace: Workspace(name: "Hooks", primaryPath: checkout),
            runtime: runtime
        )
        if readOnly { task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"] }
        task.templateHooksJSON = Self.hooks
        return task
    }

    @Test("Only Claude Code, or a runtime ASTRA cannot name, claims the checkout settings")
    func claimSidePolicy() {
        #expect(TemplateHookInjectionPolicy.claimsCheckoutSettings(hooksJSON: Self.hooks, runtimeRawValue: "claude_code"))
        // Unknown never reads as "does not read the file".
        #expect(TemplateHookInjectionPolicy.claimsCheckoutSettings(hooksJSON: Self.hooks, runtimeRawValue: nil))
        #expect(TemplateHookInjectionPolicy.claimsCheckoutSettings(hooksJSON: Self.hooks, runtimeRawValue: " "))
        #expect(TemplateHookInjectionPolicy.claimsCheckoutSettings(hooksJSON: Self.hooks, runtimeRawValue: "future_cli"))
        for runtime in Self.otherRuntimes {
            #expect(!TemplateHookInjectionPolicy.claimsCheckoutSettings(
                hooksJSON: Self.hooks, runtimeRawValue: runtime.rawValue), "\(runtime.rawValue)")
        }
        for empty in ["", "{}"] {
            #expect(!TemplateHookInjectionPolicy.claimsCheckoutSettings(hooksJSON: empty, runtimeRawValue: "claude_code"))
        }
    }

    @Test("A launch never injects where admission did not claim")
    func launchNeverWritesWithoutTheClaim() {
        // Every runtime the registry knows, plus one it does not.
        let runtimes = [AgentRuntimeID.claudeCode] + Self.otherRuntimes + [AgentRuntimeID(rawValue: "future_cli")!]
        for runtime in runtimes {
            let claimed = TemplateHookInjectionPolicy.claimsCheckoutSettings(
                hooksJSON: Self.hooks, runtimeRawValue: runtime.rawValue)
            for access in TaskExecutionResourceAccess.allCases {
                let injects = TemplateHookInjectionPolicy.injects(
                    hooksJSON: Self.hooks, runtime: runtime, workspaceAccess: access)
                // Injection implies both the claim and an exclusive lease.
                #expect(!injects || (claimed && access == .exclusive), "\(runtime.rawValue) \(access.rawValue)")
            }
            #expect(TemplateHookInjectionPolicy.injects(
                hooksJSON: Self.hooks, runtime: runtime, workspaceAccess: .exclusive) == claimed)
        }
    }

    @Test("A Claude Code task with hooks claims its checkout exclusively; other runtimes keep a declared reader")
    func claimsFollowTheRuntime() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }

        let claude = task(.claudeCode, in: checkout)
        #expect(TaskExecutionResourceClaimResolver.claims(for: claude).allSatisfy { $0.access == .exclusive })
        #expect(TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: nil, task: claude))

        for runtime in Self.otherRuntimes {
            let other = task(runtime, in: checkout)
            let claims = TaskExecutionResourceClaimResolver.claims(for: other)
            #expect(claims.first?.access == .shared, "\(runtime.rawValue)")
            #expect(!TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: nil, task: other))

            // The frozen request decides, not a runtime the task was moved to later.
            let request = TaskTurnRequest(task: other, messageEventID: UUID(), sequence: 1, resourceClaims: claims)
            other.runtimeID = AgentRuntimeID.claudeCode.rawValue
            #expect(!TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: request, task: other))
            #expect(TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: nil, task: other))
        }

        // A request frozen for Claude Code keeps its exclusive workflow.
        let frozen = TaskTurnRequest(task: claude, messageEventID: UUID(), sequence: 1,
                                     resourceClaims: TaskExecutionResourceClaimResolver.claims(for: claude))
        claude.runtimeID = AgentRuntimeID.codexCLI.rawValue
        #expect(TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: frozen, task: claude))
    }

    @Test("Hooks reach the checkout only for Claude Code holding it exclusively, and are restored")
    func scopeInjectsAndRestores() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }
        let original = #"{"custom":true}"#
        try FileManager.default.createDirectory(
            atPath: ClaudeSettingsStore.settingsDirectory(for: checkout), withIntermediateDirectories: true)
        try original.write(toFile: settingsPath(checkout), atomically: true, encoding: .utf8)
        func settings() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: settingsPath(checkout)))) as? [String: Any])
        }

        let scope = RuntimeTemplateHookScope(task: task(.claudeCode, in: checkout, readOnly: false),
                                             path: checkout, runtime: .claudeCode, workspaceAccess: .exclusive)
        #expect((try settings()["hooks"] as? [String: Any])?["PreToolUse"] != nil)
        scope.restore()
        #expect(try settings()["hooks"] == nil)
        #expect(try settings()["custom"] as? Bool == true)
    }

    @Test("A runtime that ignores the file, or a shared lease, leaves the checkout untouched")
    func scopeLeavesTheCheckoutAlone() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }

        var launches: [(AgentRuntimeID, TaskExecutionResourceAccess)] = Self.otherRuntimes.map { ($0, .exclusive) }
        launches.append((.claudeCode, .shared))
        for (runtime, access) in launches {
            let scope = RuntimeTemplateHookScope(task: task(runtime, in: checkout), path: checkout,
                                                 runtime: runtime, workspaceAccess: access)
            #expect(!FileManager.default.fileExists(atPath: settingsPath(checkout)), "\(runtime.rawValue)")
            // The provider may write its own settings during the run; restore
            // must not treat them as something to clean up.
            try FileManager.default.createDirectory(
                atPath: ClaudeSettingsStore.settingsDirectory(for: checkout), withIntermediateDirectories: true)
            let written = #"{"hooks":{"Stop":[{"hooks":[]}]}}"#
            try written.write(toFile: settingsPath(checkout), atomically: true, encoding: .utf8)
            scope.restore()
            #expect(try String(contentsOfFile: settingsPath(checkout), encoding: .utf8) == written)
            try FileManager.default.removeItem(atPath: ClaudeSettingsStore.settingsDirectory(for: checkout))
        }
    }

    @Test("Hooks are written only into a folder the admitted lease holds as a writer")
    func hooksNeedTheLeaseToCoverTheirFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-hook-lease-\(UUID().uuidString)", isDirectory: true)
        let held = root.appendingPathComponent("held").path
        let moved = root.appendingPathComponent("moved").path
        try FileManager.default.createDirectory(atPath: held + "/nested", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func claim(_ key: String, _ access: TaskResourceAccessMode, _ kind: TaskExecutionResourceKind = .workspace) -> TaskResourceLockClaim {
            TaskResourceLockClaim(taskID: UUID(), resourceKey: key, accessMode: access, runMode: "test", resourceKind: kind)
        }
        func injects(_ path: String, _ lease: [TaskResourceLockClaim]?) -> Bool {
            TemplateHookInjectionPolicy.injects(
                hooksJSON: #"{"PreToolUse":[]}"#, runtime: .claudeCode, workspaceAccess: .exclusive, path: path, lease: lease)
        }

        #expect(injects(held, [claim(held, .write)]))
        #expect(injects(held + "/nested", [claim(held, .write)]))
        // The checkout moved while the request was queued: the lease covers
        // the old folder, not the one the hooks would be written into.
        #expect(!injects(moved, [claim(held, .write)]))
        // A reader's claim, or one of another kind, does not cover a write.
        #expect(!injects(held, [claim(held, .readOnly)]))
        #expect(!injects(held, [claim(held, .write, .docker)]))
        // A launch admission never saw keeps the access check alone.
        #expect(injects(moved, nil))
    }
}
