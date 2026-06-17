# Real Provider E2E Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ASTRA's real-provider E2E suite truthful, diagnosable, and passing for the provider accounts that are actually configured on this machine.

**Architecture:** Keep live-test concerns in test support files with single responsibilities: configuration, readiness, diagnostics, and per-provider capability expectations. Product code changes should be limited to durable artifact verification where the live run exposed a real mismatch between recorded run evidence and completion policy. Do not hide provider setup failures by skipping tests; fail fast with the exact missing prerequisite and keep long E2E assertions focused on ASTRA behavior.

**Tech Stack:** Swift 5.10, Swift Testing, SwiftData, SwiftPM, ASTRA runtime adapters, provider CLIs (`claude`, `copilot`, `agy`, `cursor-agent`, `opencode`).

---

## Failure Baseline

Observed commands on June 16, 2026:

```bash
RUN_E2E=1 RUN_REAL_PROVIDERS=1 swift test
```

Result:

```text
Test run with 2744 tests in 316 suites failed after 544.146 seconds with 60 issues.
```

Control command:

```bash
swift test
```

Result:

```text
Test run with 2744 tests in 316 suites passed after 70.801 seconds.
```

Real failures to address:

- `RealProviderSmokeTests` still uses `claude-opus-4-6@default` as an artifact fallback model even though live Claude model discovery returned `claude-sonnet-4-6` as available.
- `opencode` is installed but unauthenticated; `opencode auth list` returned `0 credentials`.
- Cursor live runs return token usage but no cost and no structured `tool.use` events, while `E2ETestSupport.RuntimeCase` currently expects both.
- Copilot Phase 1 can create the requested files but leave the task `pending_user` because deliverable verification fails; the test currently accepts `pendingUser` as terminal and then contradicts itself by requiring `task.completed`.
- Claude Phase 1-3 live E2E exits with code `1` and zero tokens, but Phase tests do not print the provider error payload before deleting the temp workspace.

## File Map

- Create `Tests/LiveProviderTestConfiguration.swift`
  - Owns environment-derived model choices for live tests.
- Create `Tests/LiveProviderDiagnostics.swift`
  - Builds and prints redacted task/run summaries for Phase 1-3 live E2E failures.
- Create `Tests/LiveProviderReadiness.swift`
  - Performs fast test-only prerequisite checks before launching long real-provider tasks.
- Create `Tests/LiveProviderSupportTests.swift`
  - Unit tests for live model configuration, readiness parsing, and diagnostics redaction.
- Modify `Tests/E2ETestSupport.swift`
  - Uses `LiveProviderTestConfiguration`.
  - Adds provider capability expectations that match actual adapter behavior.
  - Runs fast readiness checks during live E2E configuration.
- Modify `Tests/Phase1FunctionalTest.swift`
  - Prints diagnostics before assertions.
  - Requires completed deliverable flow, not merely any terminal state.
  - Uses capability-based evidence expectations.
- Modify `Tests/Phase2FunctionalTest.swift`
  - Prints diagnostics before assertions.
  - Uses capability-based evidence expectations.
- Modify `Tests/Phase3FunctionalTest.swift`
  - Prints diagnostics before assertions.
  - Uses capability-based evidence expectations.
- Modify `Tests/RealProviderSmokeTests.swift`
  - Removes stale Claude artifact model fallback.
  - Reuses the shared live configuration helper.
- Modify `Tests/TaskDeliverableVerificationServiceTests.swift`
  - Adds a regression for workspace-root artifacts created during the run.
- Modify `Astra/Services/Validation/TaskDeliverableVerificationService.swift`
  - Aligns verification evidence discovery with the artifact evidence ASTRA already records for the run, if the regression proves the mismatch.
- Modify `Astra/Services/Persistence/TaskOutputDiscovery.swift` or `Astra/Services/Persistence/TaskArtifactPersistenceService.swift`
  - Only if the regression shows verification cannot discover run-scoped workspace artifacts through the current persistence service boundary.

## Task 1: Preserve The Baseline And Start A Branch

**Files:**
- No source changes.

- [ ] **Step 1: Confirm clean checkout**

Run:

```bash
git status --short --branch
```

Expected:

```text
## main...origin/main
```

- [ ] **Step 2: Create a branch**

Run:

```bash
git switch -c alvaro/real-provider-e2e-remediation
```

Expected:

```text
Switched to a new branch 'alvaro/real-provider-e2e-remediation'
```

- [ ] **Step 3: Record current non-live baseline**

Run:

```bash
swift test
```

Expected:

```text
Test run with 2744 tests in 316 suites passed
```

Do not continue if the non-live suite fails; that would mean the branch picked up an unrelated regression.

## Task 2: Centralize Live Provider Model Configuration

**Files:**
- Create: `Tests/LiveProviderTestConfiguration.swift`
- Modify: `Tests/LiveProviderSupportTests.swift`
- Modify: `Tests/E2ETestSupport.swift`
- Modify: `Tests/RealProviderSmokeTests.swift`

- [ ] **Step 1: Write failing configuration tests**

Create `Tests/LiveProviderSupportTests.swift` with:

```swift
import Testing
@testable import ASTRA

@Suite("Live provider test support")
struct LiveProviderSupportTests {
    @Test("Claude artifact model falls back to the supported Claude default")
    func claudeArtifactModelFallsBackToSupportedDefault() {
        let config = LiveProviderTestConfiguration(environment: [:])

        #expect(config.claudeModel == AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode))
        #expect(config.claudeArtifactModel == AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode))
        #expect(config.claudeArtifactModel != "claude-opus-4-6@default")
    }

    @Test("Claude artifact model honors explicit artifact override before general Claude override")
    func claudeArtifactModelHonorsOverrideOrder() {
        let config = LiveProviderTestConfiguration(environment: [
            "REAL_CLAUDE_MODEL": "claude-sonnet-override",
            "REAL_CLAUDE_ARTIFACT_MODEL": "claude-artifact-override"
        ])

        #expect(config.claudeModel == "claude-sonnet-override")
        #expect(config.claudeArtifactModel == "claude-artifact-override")
    }

    @Test("Claude artifact model falls back to general Claude override")
    func claudeArtifactModelFallsBackToGeneralOverride() {
        let config = LiveProviderTestConfiguration(environment: [
            "REAL_CLAUDE_MODEL": "claude-live-default"
        ])

        #expect(config.claudeModel == "claude-live-default")
        #expect(config.claudeArtifactModel == "claude-live-default")
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
swift test --filter LiveProviderSupportTests
```

Expected:

```text
error: cannot find 'LiveProviderTestConfiguration' in scope
```

- [ ] **Step 3: Add the configuration helper**

Create `Tests/LiveProviderTestConfiguration.swift` with:

```swift
import Foundation
@testable import ASTRA

struct LiveProviderTestConfiguration: Sendable, Equatable {
    var environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var claudeModel: String {
        configured("REAL_CLAUDE_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode)
    }

    var claudeArtifactModel: String {
        configured("REAL_CLAUDE_ARTIFACT_MODEL")
            ?? configured("REAL_CLAUDE_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode)
    }

    var copilotModel: String {
        configured("REAL_COPILOT_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
    }

    var copilotArtifactModel: String {
        configured("REAL_COPILOT_ARTIFACT_MODEL")
            ?? configured("REAL_COPILOT_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
    }

    var antigravityModel: String {
        configured("REAL_ANTIGRAVITY_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .antigravityCLI)
    }

    var cursorModel: String {
        configured("REAL_CURSOR_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .cursorCLI)
    }

    var openCodeModel: String {
        configured("REAL_OPENCODE_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .openCodeCLI)
    }

    private func configured(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
```

- [ ] **Step 4: Use the helper in `E2ETestSupport.runtimeCases(environment:)`**

In `Tests/E2ETestSupport.swift`, replace direct environment lookups in `runtimeCases(environment:)` with:

```swift
let config = LiveProviderTestConfiguration(environment: environment)
let cases = [
    RuntimeCase(
        runtimeID: .claudeCode,
        model: config.claudeModel,
        directoryNameComponent: "claude",
        expectsSessionID: true,
        expectsUsageStats: true,
        expectsCostUSD: true,
        expectsTeamEvents: true,
        expectsStructuredToolEvents: true,
        expectsResultCallback: true
    ),
    RuntimeCase(
        runtimeID: .copilotCLI,
        model: config.copilotModel,
        directoryNameComponent: "copilot",
        expectsSessionID: false,
        expectsUsageStats: false,
        expectsCostUSD: false,
        expectsTeamEvents: false,
        expectsStructuredToolEvents: true,
        expectsResultCallback: true
    ),
    RuntimeCase(
        runtimeID: .antigravityCLI,
        model: config.antigravityModel,
        directoryNameComponent: "antigravity",
        expectsSessionID: false,
        expectsUsageStats: false,
        expectsCostUSD: false,
        expectsTeamEvents: false,
        expectsStructuredToolEvents: false,
        expectsResultCallback: false
    ),
    RuntimeCase(
        runtimeID: .cursorCLI,
        model: config.cursorModel,
        directoryNameComponent: "cursor",
        expectsSessionID: true,
        expectsUsageStats: true,
        expectsCostUSD: false,
        expectsTeamEvents: false,
        expectsStructuredToolEvents: false,
        expectsResultCallback: true
    ),
    RuntimeCase(
        runtimeID: .openCodeCLI,
        model: config.openCodeModel,
        directoryNameComponent: "opencode",
        expectsSessionID: false,
        expectsUsageStats: false,
        expectsCostUSD: false,
        expectsTeamEvents: false,
        expectsStructuredToolEvents: false,
        expectsResultCallback: true
    )
]
```

This intentionally changes Cursor and OpenCode expectations to match the observed adapter facts: Cursor produced tokens without cost or `tool.use`; OpenCode should not be expected to provide a native provider session unless the adapter actually records one.

- [ ] **Step 5: Use the helper in `RealProviderSmokeTests`**

In `Tests/RealProviderSmokeTests.swift`, add:

```swift
private static var liveConfig: LiveProviderTestConfiguration {
    LiveProviderTestConfiguration()
}
```

Replace:

```swift
let claudeModel = ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"] ?? "claude-sonnet-4-6"
let copilotModel = ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
```

with:

```swift
let claudeModel = Self.liveConfig.claudeModel
let copilotModel = Self.liveConfig.copilotModel
```

Replace both artifact-model blocks:

```swift
let model = ProcessInfo.processInfo.environment["REAL_CLAUDE_ARTIFACT_MODEL"]
    ?? ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"]
    ?? "claude-opus-4-6@default"
```

with:

```swift
let model = Self.liveConfig.claudeArtifactModel
```

Replace the Copilot artifact-model block:

```swift
let model = ProcessInfo.processInfo.environment["REAL_COPILOT_ARTIFACT_MODEL"]
    ?? ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"]
    ?? "gpt-5.3-codex"
```

with:

```swift
let model = Self.liveConfig.copilotArtifactModel
```

- [ ] **Step 6: Verify the configuration tests pass**

Run:

```bash
swift test --filter LiveProviderSupportTests
```

Expected:

```text
Test run ... passed
```

- [ ] **Step 7: Commit**

Run:

```bash
git add Tests/LiveProviderTestConfiguration.swift Tests/LiveProviderSupportTests.swift Tests/E2ETestSupport.swift Tests/RealProviderSmokeTests.swift
git commit -m "test: centralize live provider model configuration"
```

## Task 3: Add Redacted Live E2E Diagnostics Before Assertions

**Files:**
- Create: `Tests/LiveProviderDiagnostics.swift`
- Modify: `Tests/LiveProviderSupportTests.swift`
- Modify: `Tests/Phase1FunctionalTest.swift`
- Modify: `Tests/Phase2FunctionalTest.swift`
- Modify: `Tests/Phase3FunctionalTest.swift`

- [ ] **Step 1: Add failing diagnostics tests**

Append to `Tests/LiveProviderSupportTests.swift`:

```swift
@Suite("Live provider diagnostics")
struct LiveProviderDiagnosticsTests {
    @Test("redaction removes common provider secrets")
    func redactionRemovesCommonProviderSecrets() {
        let redacted = LiveProviderDiagnostics.redacted(
            "OPENAI_API_KEY=sk-test-secret gh token gho_abcdefghijklmnop"
        )

        #expect(!redacted.contains("sk-test-secret"))
        #expect(!redacted.contains("gho_abcdefghijklmnop"))
        #expect(redacted.contains("sk-[redacted]"))
        #expect(redacted.contains("gho_[redacted]"))
    }
}
```

- [ ] **Step 2: Run the failing diagnostics tests**

Run:

```bash
swift test --filter LiveProviderDiagnosticsTests
```

Expected:

```text
error: cannot find 'LiveProviderDiagnostics' in scope
```

- [ ] **Step 3: Add the diagnostics helper**

Create `Tests/LiveProviderDiagnostics.swift` with:

```swift
import Foundation
@testable import ASTRA
import ASTRACore

enum LiveProviderDiagnostics {
    @MainActor
    static func printSummary(
        label: String,
        task: AgentTask,
        workspacePath: String,
        receivedEvents: [ParsedEvent] = []
    ) {
        print(summary(
            label: label,
            task: task,
            workspacePath: workspacePath,
            receivedEvents: receivedEvents
        ))
    }

    @MainActor
    static func summary(
        label: String,
        task: AgentTask,
        workspacePath: String,
        receivedEvents: [ParsedEvent] = []
    ) -> String {
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let run = runs.last
        let runID = run?.id
        let scopedEvents = task.events
            .filter { event in
                guard let runID else { return true }
                return event.run?.id == runID
            }
        let errorEvents = scopedEvents
            .filter { $0.type == "error" }
            .map { redacted(String($0.payload.prefix(1_000))) }
        let verificationEvents = scopedEvents
            .filter { $0.type.hasPrefix("deliverable.verification.") }
            .map { "\($0.type): \(redacted(String($0.payload.prefix(1_000))))" }
        let eventTypes = Set(scopedEvents.map(\.type)).sorted().joined(separator: ", ")
        let artifacts = task.artifacts
            .map(\.path)
            .sorted()
            .joined(separator: ", ")
        let fileChanges = run?.fileChanges
            .map(\.path)
            .sorted()
            .joined(separator: ", ") ?? ""
        let output = redacted(String((run?.output ?? "").prefix(1_000)))

        return """

        === \(label) live E2E debug ===
        task_status=\(task.status.rawValue)
        run_status=\(run?.status.rawValue ?? "nil")
        stop_reason=\(run?.stopReason ?? "nil")
        runtime=\(run?.runtimeID ?? "nil")
        provider_version=\(run?.providerVersion ?? "nil")
        exit_code=\(run?.exitCode.map(String.init) ?? "nil")
        session=\(run?.providerSessionId.map { String($0.prefix(8)) } ?? "nil")
        workspace=\(workspacePath)
        task_folder=\(TaskWorkspaceAccess(task: task).taskFolder)
        event_types=\(eventTypes)
        received_event_count=\(receivedEvents.count)
        file_changes=\(fileChanges)
        artifacts=\(artifacts)
        output=\(output)
        verification_events=\(verificationEvents.joined(separator: " | "))
        error_events=\(errorEvents.joined(separator: " | "))
        ================================
        """
    }

    static func redacted(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"gho_[A-Za-z0-9_]+"#,
                with: "gho_[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_-]+"#,
                with: "sk-[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN)=\S+"#,
                with: "$1=[redacted]",
                options: .regularExpression
            )
    }
}
```

- [ ] **Step 4: Print diagnostics in Phase 1**

In `Tests/Phase1FunctionalTest.swift`, immediately after the `withLiveProviderSlot` block, add:

```swift
LiveProviderDiagnostics.printSummary(
    label: "Phase 1 \(runtimeCase.runtimeID.displayName)",
    task: task,
    workspacePath: testDir,
    receivedEvents: receivedEvents
)
```

- [ ] **Step 5: Print diagnostics in Phase 2**

In `Tests/Phase2FunctionalTest.swift`, immediately after the `withLiveProviderSlot` block, add:

```swift
LiveProviderDiagnostics.printSummary(
    label: "Phase 2 \(runtimeCase.runtimeID.displayName)",
    task: task,
    workspacePath: testDir,
    receivedEvents: receivedEvents
)
```

- [ ] **Step 6: Print diagnostics in Phase 3**

In `Tests/Phase3FunctionalTest.swift`, immediately after the `withLiveProviderSlot` block in `parallelDebateSwarm`, add:

```swift
LiveProviderDiagnostics.printSummary(
    label: "Phase 3 swarm \(runtimeCase.runtimeID.displayName)",
    task: task,
    workspacePath: testDir,
    receivedEvents: receivedEvents
)
```

In `budgetExceededKillsSwarm`, after execution, add:

```swift
LiveProviderDiagnostics.printSummary(
    label: "Phase 3 budget \(runtimeCase.runtimeID.displayName)",
    task: task,
    workspacePath: testDir
)
```

- [ ] **Step 7: Verify diagnostics tests pass**

Run:

```bash
swift test --filter LiveProviderDiagnosticsTests
```

Expected:

```text
Test run ... passed
```

- [ ] **Step 8: Reproduce focused Claude Phase 1 with diagnostic output**

Run:

```bash
RUN_E2E=1 RUN_E2E_RUNTIME=claude swift test --filter Phase1FunctionalTest
```

Expected:

```text
Phase 1 Claude Code live E2E debug
error_events=...
```

This command may still fail. The pass condition for this step is that the failure now prints the provider error payload before the temporary workspace is removed.

- [ ] **Step 9: Commit**

Run:

```bash
git add Tests/LiveProviderDiagnostics.swift Tests/LiveProviderSupportTests.swift Tests/Phase1FunctionalTest.swift Tests/Phase2FunctionalTest.swift Tests/Phase3FunctionalTest.swift
git commit -m "test: print live provider e2e diagnostics"
```

## Task 4: Fail Fast On Missing Live Provider Prerequisites

**Files:**
- Create: `Tests/LiveProviderReadiness.swift`
- Modify: `Tests/LiveProviderSupportTests.swift`
- Modify: `Tests/E2ETestSupport.swift`

- [ ] **Step 1: Add failing readiness tests**

Append to `Tests/LiveProviderSupportTests.swift`:

```swift
@Suite("Live provider readiness")
struct LiveProviderReadinessTests {
    @Test("OpenCode readiness blocks zero credentials")
    func openCodeReadinessBlocksZeroCredentials() {
        let result = LiveProviderReadiness.check(
            runtimeID: .openCodeCLI,
            executablePath: "/usr/bin/opencode",
            runCommand: { _, _ in
                LiveProviderReadiness.CommandResult(exitCode: 0, output: "Credentials ~/.local/share/opencode/auth.json\n0 credentials\n")
            }
        )

        #expect(result?.message.contains("opencode auth login") == true)
        #expect(result?.message.contains("0 credentials") == true)
    }

    @Test("OpenCode readiness accepts configured credentials")
    func openCodeReadinessAcceptsConfiguredCredentials() {
        let result = LiveProviderReadiness.check(
            runtimeID: .openCodeCLI,
            executablePath: "/usr/bin/opencode",
            runCommand: { _, _ in
                LiveProviderReadiness.CommandResult(exitCode: 0, output: "Credentials ~/.local/share/opencode/auth.json\n1 credential\n")
            }
        )

        #expect(result == nil)
    }
}
```

- [ ] **Step 2: Run the failing readiness tests**

Run:

```bash
swift test --filter LiveProviderReadinessTests
```

Expected:

```text
error: cannot find 'LiveProviderReadiness' in scope
```

- [ ] **Step 3: Add readiness support**

Create `Tests/LiveProviderReadiness.swift` with:

```swift
import Foundation
@testable import ASTRA

enum LiveProviderReadiness {
    struct CommandResult: Equatable {
        var exitCode: Int
        var output: String
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        var runtimeID: AgentRuntimeID
        var message: String

        var description: String { message }
    }

    typealias CommandRunner = (_ executablePath: String, _ arguments: [String]) -> CommandResult

    static func requireReady(runtimeID: AgentRuntimeID, executablePath: String) throws {
        if let failure = check(runtimeID: runtimeID, executablePath: executablePath) {
            throw failure
        }
    }

    static func check(
        runtimeID: AgentRuntimeID,
        executablePath: String,
        runCommand: CommandRunner = run
    ) -> Failure? {
        switch runtimeID {
        case .openCodeCLI:
            let result = runCommand(executablePath, ["auth", "list"])
            guard result.exitCode == 0,
                  OpenCodeCLIRuntime.authListShowsConfiguredCredentials(result.output) else {
                let evidence = LiveProviderDiagnostics.redacted(String(result.output.prefix(500)))
                return Failure(
                    runtimeID: runtimeID,
                    message: "OpenCode CLI is installed but not authenticated for live E2E. Run `opencode auth login`, verify `opencode auth list` shows at least 1 credential, then rerun. Evidence: \(evidence)"
                )
            }
            return nil
        default:
            return nil
        }
    }

    private static func run(executablePath: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: Int(process.terminationStatus), output: output + error)
    }
}
```

- [ ] **Step 4: Call readiness from E2E executable configuration**

In `Tests/E2ETestSupport.swift`, in each `configureExecutable` case after the executable path is assigned or validated, call:

```swift
if ProcessInfo.processInfo.environment["RUN_E2E"] != nil {
    try LiveProviderReadiness.requireReady(runtimeID: runtimeID, executablePath: path)
}
```

For example, the OpenCode case should become:

```swift
case .openCodeCLI:
    let path = RuntimePathResolver.detectOpenCodePath()
    guard FileManager.default.isExecutableFile(atPath: path) else {
        throw E2ETestSupportError.missingExecutable("opencode")
    }
    try LiveProviderReadiness.requireReady(runtimeID: runtimeID, executablePath: path)
    worker.setExecutablePath(path, for: .openCodeCLI)
```

- [ ] **Step 5: Verify readiness tests pass**

Run:

```bash
swift test --filter LiveProviderReadinessTests
```

Expected:

```text
Test run ... passed
```

- [ ] **Step 6: Verify OpenCode now fails fast with root cause**

Run:

```bash
RUN_E2E=1 RUN_E2E_RUNTIME=opencode swift test --filter Phase1FunctionalTest
```

Expected while the machine still has `0 credentials`:

```text
OpenCode CLI is installed but not authenticated for live E2E. Run `opencode auth login`
```

- [ ] **Step 7: Machine setup action for real OpenCode E2E**

Run in an interactive terminal:

```bash
opencode auth login
opencode auth list
```

Expected:

```text
1 credential
```

If this machine should not run OpenCode real calls, run the live suite with `RUN_E2E_RUNTIME` filters for the configured providers instead of pretending OpenCode passed.

- [ ] **Step 8: Commit**

Run:

```bash
git add Tests/LiveProviderReadiness.swift Tests/LiveProviderSupportTests.swift Tests/E2ETestSupport.swift
git commit -m "test: fail fast for unauthenticated live providers"
```

## Task 5: Make E2E Assertions Match Provider Capabilities Without Weakening Artifact Completion

**Files:**
- Modify: `Tests/E2ETestSupport.swift`
- Modify: `Tests/Phase1FunctionalTest.swift`
- Modify: `Tests/Phase2FunctionalTest.swift`
- Modify: `Tests/Phase3FunctionalTest.swift`
- Modify: `Tests/LiveProviderSupportTests.swift`

- [ ] **Step 1: Add capability-matrix tests**

Append to `LiveProviderSupportTests`:

```swift
@Suite("Live provider runtime cases")
struct LiveProviderRuntimeCaseTests {
    @Test("Cursor tokens are expected but cost and structured tool events are optional")
    func cursorExpectationsMatchObservedAdapterTelemetry() {
        let cursor = E2ETestSupport.runtimeCases(environment: ["RUN_E2E_RUNTIME": "cursor"]).first

        #expect(cursor?.expectsUsageStats == true)
        #expect(cursor?.expectsCostUSD == false)
        #expect(cursor?.expectsStructuredToolEvents == false)
    }

    @Test("OpenCode does not require provider sessions before the adapter records them")
    func openCodeSessionExpectationIsNotAssumed() {
        let openCode = E2ETestSupport.runtimeCases(environment: ["RUN_E2E_RUNTIME": "opencode"]).first

        #expect(openCode?.expectsSessionID == false)
        #expect(openCode?.expectsStructuredToolEvents == false)
    }
}
```

- [ ] **Step 2: Run the focused capability tests**

Run:

```bash
swift test --filter LiveProviderRuntimeCaseTests
```

Expected before Task 2 Step 4 is applied:

```text
Expectation failed
```

Expected after Task 2 Step 4:

```text
Test run ... passed
```

- [ ] **Step 3: Tighten Phase 1 completion semantics**

In `Tests/Phase1FunctionalTest.swift`, replace:

```swift
let isTerminal = task.isTerminal || task.status == .pendingUser
#expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
#expect(task.status != .failed, "Task should not have failed, status: \(task.status.rawValue)")
```

with:

```swift
#expect(task.status == .completed, "Artifact E2E should complete, got: \(task.status.rawValue)")
```

Keep the `#expect(eventTypes.contains("task.completed"))` assertion. A provider that produces files but leaves the task pending has exposed a validation/runtime issue and should not be accepted as a passed E2E.

- [ ] **Step 4: Tighten Phase 2 completion semantics**

In `Tests/Phase2FunctionalTest.swift`, replace:

```swift
let isTerminal = task.isTerminal || task.status == .pendingUser || task.status == .budgetExceeded
#expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
#expect(task.status != .failed, "Task should not have failed, status: \(task.status.rawValue)")
```

with:

```swift
#expect(task.status == .completed, "Team artifact E2E should complete, got: \(task.status.rawValue)")
```

Keep the existing budget-exceeded block for the separate budget stress test only. The maker/checker task has a real deliverable and should finish completed.

- [ ] **Step 5: Tighten Phase 3 swarm completion semantics**

In `Tests/Phase3FunctionalTest.swift`, in `parallelDebateSwarm`, replace:

```swift
let isTerminal = task.isTerminal || task.status == .pendingUser || task.status == .budgetExceeded
#expect(isTerminal, "Task should reach terminal status, got: \(task.status.rawValue)")
```

with:

```swift
#expect(task.status == .completed, "Swarm artifact E2E should complete, got: \(task.status.rawValue)")
```

Leave `budgetExceededKillsSwarm` as a budget-specific test that accepts `budgetExceeded`.

- [ ] **Step 6: Verify the non-live suite still passes**

Run:

```bash
swift test
```

Expected:

```text
Test run with 2744 tests in 316 suites passed
```

- [ ] **Step 7: Commit**

Run:

```bash
git add Tests/E2ETestSupport.swift Tests/Phase1FunctionalTest.swift Tests/Phase2FunctionalTest.swift Tests/Phase3FunctionalTest.swift Tests/LiveProviderSupportTests.swift
git commit -m "test: align live e2e expectations with provider capabilities"
```

## Task 6: Fix Deliverable Verification To Use Run-Scoped Artifact Evidence

**Files:**
- Modify: `Tests/TaskDeliverableVerificationServiceTests.swift`
- Modify: `Astra/Services/Validation/TaskDeliverableVerificationService.swift`
- Modify only if needed: `Astra/Services/Persistence/TaskOutputDiscovery.swift`
- Modify only if needed: `Astra/Services/Persistence/TaskArtifactPersistenceService.swift`

- [ ] **Step 1: Add a regression for workspace-root run artifacts**

In `Tests/TaskDeliverableVerificationServiceTests.swift`, add:

```swift
@Test("verification accepts workspace-root artifacts recorded as run file changes")
@MainActor
func verificationAcceptsWorkspaceRootArtifactsRecordedAsRunFileChanges() async throws {
    let fixture = try makeFixture(goal: """
    Complete this small filesystem task.
    Create these final deliverables in the current working directory:
    - ./word_counter.py
    - ./sample.txt
    - ./results.txt
    """)
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }

    let wordCounter = (fixture.root as NSString).appendingPathComponent("word_counter.py")
    let sample = (fixture.root as NSString).appendingPathComponent("sample.txt")
    let results = (fixture.root as NSString).appendingPathComponent("results.txt")

    try """
    import sys
    from collections import Counter
    text = open(sys.argv[1]).read().lower().split()
    for word, count in Counter(text).most_common(5):
        print(f"{word}: {count}")
    """.write(toFile: wordCounter, atomically: true, encoding: .utf8)
    try "alpha beta alpha gamma".write(toFile: sample, atomically: true, encoding: .utf8)
    try "alpha: 2\nbeta: 1".write(toFile: results, atomically: true, encoding: .utf8)

    for path in [wordCounter, sample, results] {
        fixture.run.appendFileChange(StoredFileChange(from: FileChange(
            path: path,
            changeType: .write,
            content: try String(contentsOfFile: path, encoding: .utf8),
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )))
    }

    let result = await TaskDeliverableVerificationService.evaluate(
        task: fixture.task,
        run: fixture.run,
        modelContext: fixture.container.mainContext,
        environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
    )

    #expect(result.canComplete)
    #expect(result.status != "failed")
    #expect(result.evidencePaths.contains { $0.hasSuffix("word_counter.py") })
    #expect(result.evidencePaths.contains { $0.hasSuffix("sample.txt") })
    #expect(result.evidencePaths.contains { $0.hasSuffix("results.txt") })
}
```

- [ ] **Step 2: Run the regression and confirm it fails if the service ignores run evidence**

Run:

```bash
swift test --filter verificationAcceptsWorkspaceRootArtifactsRecordedAsRunFileChanges
```

Expected before implementation:

```text
Expectation failed: result.canComplete
```

If the test unexpectedly passes, the live Copilot failure is not this service seam; use the diagnostic payload from Task 3 to write a narrower regression around the failed `deliverable.verification.failed` check before changing product code.

- [ ] **Step 3: Add a run-aware discovery function**

If Step 2 fails, modify `Astra/Services/Persistence/TaskOutputDiscovery.swift` by adding:

```swift
@MainActor
static func files(for task: AgentTask, run: TaskRun?, fileManager: FileManager = .default) -> [TaskOutputDiscoveredFile] {
    var discovered = files(for: task, fileManager: fileManager)
    guard let run else { return discovered }

    var seen = Set(discovered.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
    let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
    let workspacePath = TaskWorkspaceAccess(task: task).effectiveWorkspacePath
    let allowedRoots = [taskFolder, workspacePath].filter { !$0.isEmpty }

    for change in run.fileChanges {
        guard let file = discoveredRunFile(
            path: change.path,
            allowedRoots: allowedRoots,
            fileManager: fileManager
        ) else { continue }
        guard seen.insert(URL(fileURLWithPath: file.path).standardizedFileURL.path).inserted else { continue }
        discovered.append(file)
    }

    return discovered.sorted {
        $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
}

private static func discoveredRunFile(
    path: String,
    allowedRoots: [String],
    fileManager: FileManager
) -> TaskOutputDiscoveredFile? {
    let url = URL(fileURLWithPath: path)
    let standardizedPath = url.standardizedFileURL.path
    let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

    guard fileManager.fileExists(atPath: standardizedPath) else { return nil }
    guard let root = allowedRoots.first(where: { root in
        let rootURL = URL(fileURLWithPath: root)
        let standardRoot = rootURL.standardizedFileURL.path
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return (standardizedPath == standardRoot || standardizedPath.hasPrefix(standardRoot + "/")) &&
            (resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/"))
    }) else {
        return nil
    }

    let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
    let relative = String(standardizedPath.dropFirst(rootPath.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !relative.isEmpty,
          TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relative) else {
        return nil
    }

    let attrs = try? fileManager.attributesOfItem(atPath: standardizedPath)
    return TaskOutputDiscoveredFile(
        path: standardizedPath,
        relativePath: relative,
        type: ArtifactKind.forPath(standardizedPath).rawValue,
        modifiedAt: attrs?[.modificationDate] as? Date
    )
}
```

- [ ] **Step 4: Use run-aware discovery in verification**

In `Astra/Services/Validation/TaskDeliverableVerificationService.swift`, replace:

```swift
let artifactReconciliation = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(
    for: task,
    modelContext: modelContext
)
```

with:

```swift
let discoveredFiles = TaskOutputDiscovery.files(for: task, run: run)
let artifactReconciliation = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(
    discoveredFiles,
    for: task,
    modelContext: modelContext
)
```

- [ ] **Step 5: Run the regression**

Run:

```bash
swift test --filter verificationAcceptsWorkspaceRootArtifactsRecordedAsRunFileChanges
```

Expected:

```text
Test run ... passed
```

- [ ] **Step 6: Run related artifact tests**

Run:

```bash
swift test --filter TaskDeliverableVerificationServiceTests
swift test --filter TaskDeliverableExpectationTests
swift test --filter TaskArtifactPersistenceServiceTests
```

Expected for each:

```text
Test run ... passed
```

- [ ] **Step 7: Commit**

Run:

```bash
git add Tests/TaskDeliverableVerificationServiceTests.swift Astra/Services/Validation/TaskDeliverableVerificationService.swift Astra/Services/Persistence/TaskOutputDiscovery.swift
git commit -m "fix: verify run-scoped workspace artifacts"
```

## Task 7: Diagnose And Fix Claude Phase 1-3 Live Tool Launch Failure

**Files:**
- Modify after evidence only: `Astra/Services/Runtime/AgentRuntimeAdapter.swift`
- Modify after evidence only: `Astra/Services/Runtime/AgentPolicyAdapters.swift`
- Modify after evidence only: `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- Modify after evidence only: focused tests under `Tests/HeadlessChatRuntimeScenarioTests.swift`, `Tests/AgentPolicyTests.swift`, or `Tests/AgentRuntimeWorkerTests.swift`

- [ ] **Step 1: Reproduce with diagnostics**

Run:

```bash
RUN_E2E=1 RUN_E2E_RUNTIME=claude swift test --filter Phase1FunctionalTest
```

Expected current failure shape:

```text
exit_code=1
task_status=failed
error_events=<provider error printed by LiveProviderDiagnostics>
```

- [ ] **Step 2: Classify the provider error**

Use the printed `error_events` and choose exactly one path:

```text
model_unavailable: error mentions selected model or access
permission_policy_mismatch: error mentions permissions, tools, Write, Bash, allowedTools, or bypassPermissions
provider_config_error: error mentions settings, config, project, or malformed JSON
```

- [ ] **Step 3: If `model_unavailable`, add a regression for normalized Claude model selection**

Add a focused test to `Tests/RuntimeModelAvailabilityTests.swift`:

```swift
@Test("live E2E Claude model resolves to a CLI-discovered model")
func liveE2EClaudeModelResolvesToDiscoveredModel() {
    let config = LiveProviderTestConfiguration(environment: [:])
    let models = ["default", "sonnet", "haiku", "claude-sonnet-4-6"]

    #expect(models.contains(config.claudeModel))
}
```

Run:

```bash
swift test --filter liveE2EClaudeModelResolvesToDiscoveredModel
```

Expected:

```text
Test run ... passed
```

If this passes, do not change production model code; the failure is not model selection.

- [ ] **Step 4: If `permission_policy_mismatch`, add a regression for Claude autonomous artifact launch permissions**

Add a focused test to `Tests/AgentPolicyTests.swift`:

```swift
@Test("Claude autonomous artifact launch exposes Write and Bash when skip permissions is enabled")
func claudeAutonomousArtifactLaunchExposesWriteAndBash() throws {
    let task = AgentTask(
        title: "Word counter test",
        goal: "Create ./word_counter.py, ./sample.txt, and ./results.txt in the current working directory",
        tokenBudget: 250_000,
        model: "claude-sonnet-4-6"
    )
    task.runtimeID = AgentRuntimeID.claudeCode.rawValue
    let render = ClaudePolicyAdapter().render(
        request: ProviderPolicyRenderRequest(
            task: task,
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: .autonomous,
            policyScope: .builtInDefault,
            liveApprovals: false,
            skipPermissions: true,
            additionalAllowedTools: [],
            additionalAskFirstTools: [],
            additionalDeniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            mcpServerIDs: [],
            runtimeSupportTools: []
        )
    )

    #expect(render.allowedTools.contains("Write"))
    #expect(render.allowedTools.contains("Bash"))
    #expect(render.cliArgumentsSummary.joined(separator: " ").contains("bypass") || render.usesBroadProviderPermissions)
}
```

Run:

```bash
swift test --filter claudeAutonomousArtifactLaunchExposesWriteAndBash
```

Expected before the fix:

```text
Expectation failed
```

Implement the minimum policy adapter change that makes this test pass. Do not alter Copilot, Cursor, Antigravity, or OpenCode policy behavior in the same commit.

- [ ] **Step 5: If `provider_config_error`, add a regression for generated Claude settings**

Add the regression in the test file that already covers Claude policy/settings generation. The test must assert that generated Claude settings are valid JSON and include the task-local permission block without stale local project settings overriding it:

```swift
@Test("Claude generated settings for live E2E are valid and policy-owned")
func claudeGeneratedSettingsForLiveE2EAreValidAndPolicyOwned() throws {
    let task = AgentTask(
        title: "Word counter test",
        goal: "Create ./word_counter.py, ./sample.txt, and ./results.txt",
        tokenBudget: 250_000,
        model: "claude-sonnet-4-6"
    )
    task.runtimeID = AgentRuntimeID.claudeCode.rawValue

    let render = ClaudePolicyAdapter().render(
        request: ProviderPolicyRenderRequest(
            task: task,
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: .autonomous,
            policyScope: .builtInDefault,
            liveApprovals: false,
            skipPermissions: true,
            additionalAllowedTools: [],
            additionalAskFirstTools: [],
            additionalDeniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            mcpServerIDs: [],
            runtimeSupportTools: []
        )
    )

    let data = try #require(render.generatedConfigPreview.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data)
    #expect(object is [String: Any])
    #expect(render.configOwnership == .generated)
}
```

Run:

```bash
swift test --filter claudeGeneratedSettingsForLiveE2EAreValidAndPolicyOwned
```

Expected before the fix:

```text
Expectation failed
```

Implement the minimum config-ownership fix that makes this test pass.

- [ ] **Step 6: Re-run focused Claude E2E**

Run:

```bash
RUN_E2E=1 RUN_E2E_RUNTIME=claude swift test --filter Phase1FunctionalTest
```

Expected:

```text
Test run ... passed
```

- [ ] **Step 7: Commit**

Run the commit matching the path actually fixed:

```bash
git add Tests Astra/Services/Runtime
git commit -m "fix: repair Claude live e2e launch"
```

## Task 8: Re-run Real Provider Smoke Tests With Correct Models

**Files:**
- No code changes unless a smoke test exposes a new root cause.

- [ ] **Step 1: Run real provider smoke tests only**

Run:

```bash
RUN_REAL_PROVIDERS=1 swift test --filter RealProviderSmokeTests
```

Expected after Task 2:

```text
Real Claude non-mail launch prunes irrelevant Graph Mail capability passed
Real Claude Masterball launch creates task output artifact passed
```

If Copilot Masterball still fails with `provider_no_actionable_progress`, keep the failure. That is a real provider behavior signal: Copilot streamed only liveness/thinking for 180 seconds without visible text, tool use, tool output, file changes, or a result. Do not mask it by increasing the timeout until a focused prompt/progress regression proves the ASTRA guard is too aggressive.

- [ ] **Step 2: If Copilot artifact still stalls, add a focused progress-signal test**

Use the existing `runUntilProviderProgressSignal` helper in `RealProviderSmokeTests.swift` and create a smaller Copilot artifact prompt:

```swift
@Test(
    "Real Copilot emits actionable progress before long artifact work",
    .enabled(if: realProviderSmokeEnabled, "Set RUN_REAL_PROVIDERS=1 to run account-backed provider smoke tests")
)
func realCopilotArtifactPromptEmitsActionableProgress() async throws {
    let harness = try RealProviderHarness()
    defer { harness.cleanup() }

    let copilotPath = try #require(Self.findExecutable("copilot"))
    let worker = harness.makeWorker(copilotPath: copilotPath)
    worker.timeoutSeconds = 60
    let task = harness.makeTask(
        runtime: .copilotCLI,
        goal: "Create a minimal index.html with the text ASTRA_COPILOT_ARTIFACT_OK.",
        model: Self.liveConfig.copilotArtifactModel
    )
    _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
    try harness.context.save()

    _ = try await harness.execute(task: task, worker: worker)
    let run = try #require(task.runs.first)
    Self.printRunSummary(label: "real copilot minimal artifact", task: task, run: run)

    #expect(run.status == .completed)
    #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: run))
}
```

Run:

```bash
RUN_REAL_PROVIDERS=1 swift test --filter realCopilotArtifactPromptEmitsActionableProgress
```

Expected:

```text
Test run ... passed
```

If this smaller prompt passes, keep the long Masterball test but lower its scope or split it into a minimal artifact smoke plus a separate non-required exploratory benchmark. If this smaller prompt also stalls, investigate Copilot policy/tool exposure rather than extending timeouts.

- [ ] **Step 3: Commit only if the smoke test changes**

Run:

```bash
git add Tests/RealProviderSmokeTests.swift
git commit -m "test: narrow copilot artifact smoke prompt"
```

## Task 9: Full Verification Matrix

**Files:**
- No source changes.

- [ ] **Step 1: Run focused non-live suites**

Run:

```bash
swift test --filter LiveProviderSupportTests
swift test --filter TaskDeliverableVerificationServiceTests
swift test --filter AgentPolicyTests
swift test --filter HeadlessChatRuntimeScenarioTests
```

Expected for each:

```text
Test run ... passed
```

- [ ] **Step 2: Run full non-live suite**

Run:

```bash
swift test
```

Expected:

```text
Test run with 2744 tests in 316 suites passed
```

- [ ] **Step 3: Verify provider CLI setup**

Run:

```bash
gh auth status
claude --version
copilot --version
agy --version
cursor-agent --version
opencode --version
opencode auth list
```

Expected:

```text
gh auth status exits 0
claude exits 0
copilot exits 0
agy exits 0
cursor-agent exits 0
opencode exits 0
opencode auth list reports at least 1 credential
```

- [ ] **Step 4: Run focused live E2E by provider**

Run serially:

```bash
RUN_E2E=1 RUN_E2E_RUNTIME=claude swift test --filter Phase1FunctionalTest
RUN_E2E=1 RUN_E2E_RUNTIME=copilot swift test --filter Phase1FunctionalTest
RUN_E2E=1 RUN_E2E_RUNTIME=antigravity swift test --filter Phase1FunctionalTest
RUN_E2E=1 RUN_E2E_RUNTIME=cursor swift test --filter Phase1FunctionalTest
RUN_E2E=1 RUN_E2E_RUNTIME=opencode swift test --filter Phase1FunctionalTest
```

Expected for each configured provider:

```text
Test run ... passed
```

- [ ] **Step 5: Run full live suite**

Run:

```bash
RUN_E2E=1 RUN_REAL_PROVIDERS=1 swift test
```

Expected:

```text
Test run with 2744 tests in 316 suites passed
```

- [ ] **Step 6: Whitespace check**

Run:

```bash
git diff --check
```

Expected:

```text
no output
```

- [ ] **Step 7: Final commit**

If any uncommitted fixes remain:

```bash
git status --short
git add Tests Astra/Services
git commit -m "test: stabilize real provider e2e suite"
```

## Execution Notes

- Do not use `RUN_E2E_RUNTIME` to hide a failing provider in the final full verification unless the provider is intentionally unsupported on this machine and the final report says so explicitly.
- Do not broaden timeouts until diagnostics prove ASTRA is stopping a provider that produced actionable progress too slowly. A provider streaming only liveness/thinking for 180 seconds is exactly what `provider_no_actionable_progress` is meant to catch.
- Do not change production runtime behavior for Cursor cost accounting unless the provider actually exposes cost data. The observed correct behavior is token usage with `costUSD == 0`.
- Do not accept `pending_user` for artifact E2E completion. A pending artifact task belongs in a focused validation regression, not in a passing end-to-end artifact test.

## Self-Review

- Spec coverage: The plan covers the real failures observed in the live run: stale Claude artifact model, unauthenticated OpenCode, Cursor telemetry assumptions, Copilot deliverable verification mismatch, and hidden Claude E2E provider errors.
- Placeholder scan: The plan contains no unresolved placeholder markers. The one diagnostic decision gate in Task 7 has concrete commands and exact follow-up test bodies for each observed class.
- Type consistency: New support types are `LiveProviderTestConfiguration`, `LiveProviderDiagnostics`, and `LiveProviderReadiness`; all later tasks use those names consistently.
