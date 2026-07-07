import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// "Enable a capability → apps can read it, with NO per-connector Swift." Proves the generic
/// capability-read chain end to end: a capability's CLI tool → derived contract family + implementation
/// (with a `.cli` `readExecution` spec) → publish-time registry extension (auto-`.mapped` binding) →
/// the resolver dispatching to the generic CLI executor → scalar rows. Plus the security boundary of the
/// generic executor (argv templating, value validation, fail-closed, scalar-only).
@Suite("Workspace App — generic capability read")
struct WorkspaceAppGenericCapabilityReadTests {

    // MARK: - Fixtures

    private func capabilityPackage(toolType: String = WorkspaceAppCapabilityContractDeriver.appReadToolType) -> PluginPackage {
        PluginPackage(
            id: "my-issues-cap", name: "My Issues", icon: "wrench", description: "", author: "", category: "",
            tags: [], version: "1.0.0", skills: [], connectors: [],
            localTools: [
                PluginLocalTool(name: "List Issues", description: "", icon: "list.bullet",
                                toolType: toolType, command: "gh",
                                arguments: "issue list --json number,title --state {state} --limit {limit}")
            ],
            templates: []
        )
    }

    // MARK: - Deriver (capability → contract)

    @Test("an enabled capability's workspaceAppRead CLI tool derives a contract family + CLI implementation")
    func deriverMapsAppReadTool() {
        let (families, impls) = WorkspaceAppCapabilityContractDeriver.derived(from: [capabilityPackage()])
        #expect(families.count == 1)
        #expect(impls.count == 1)
        let impl = impls[0]
        #expect(impl.familyID == families[0].id)
        #expect(impl.transport == .cli)
        #expect(impl.provider == "cli")
        // The readExecution carries the tool's command as the argv template (placeholders survive).
        let exec = impl.readExecution
        #expect(exec?.transport == .cli)
        let op = exec?.operations[WorkspaceAppCapabilityContractDeriver.defaultOperation]
        #expect(op?.command.first == "gh")
        #expect(op?.command.contains("{limit}") == true)
        #expect(op?.command.contains("{state}") == true)
    }

    @Test("a capability tool with a non-sentinel toolType is NOT exposed to apps (opt-in)")
    func deriverIgnoresNonAppReadTools() {
        let (families, impls) = WorkspaceAppCapabilityContractDeriver.derived(from: [capabilityPackage(toolType: "cli")])
        #expect(families.isEmpty)
        #expect(impls.isEmpty)
    }

    // MARK: - Registry extension (publish-time auto-map)

    @Test("the registry extended with derived contracts resolves an app requirement to a .mapped binding")
    func registryExtensionAutoMaps() {
        let (families, impls) = WorkspaceAppCapabilityContractDeriver.derived(from: [capabilityPackage()])
        let registry = WorkspaceAppContractRegistry().including(capabilityFamilies: families, implementations: impls)
        let requirement = WorkspaceAppRequirement(
            id: "mycap", contract: families[0].id, operations: ["default"], providerHint: "cli"
        )
        let resolution = registry.resolve(requirement)
        // Non-nil selectedImplementation ⇒ WorkspaceAppService.bindingStatus returns .mapped at publish.
        #expect(resolution.selectedImplementation?.id == impls[0].id)
        #expect(resolution.selectedImplementation?.readExecution != nil)
    }

    // MARK: - Generic CLI executor — security boundary

    @Test("generic CLI runner delegates process mechanics to HardenedProcessExecutor")
    func genericCLIRunnerDelegatesToSharedHardenedExecutor() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Astra/Services/WorkspaceApps/WorkspaceAppGenericCLIReadClient.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("import ASTRACore"))
        #expect(source.contains("HardenedProcessExecutor"))
        #expect(!source.contains("let process = Process()"))
        #expect(!source.contains("CLIOutputBox"))
    }

    @Test("argv templating substitutes validated params and rejects malformed/unsafe/missing values")
    func argvTemplating() throws {
        let command = ["gh", "issue", "list", "--state", "{state}", "--limit", "{limit}"]
        let argv = try WorkspaceAppGenericCLIReadClient.resolveArgv(
            command, params: ["state": "open", "limit": "30"], sourceID: "s")
        #expect(argv == ["gh", "issue", "list", "--state", "open", "--limit", "30"])

        // A value that could be read as a flag (leading dash) is rejected.
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.resolveArgv(
                command, params: ["state": "-rf", "limit": "30"], sourceID: "s")
        }
        // A partial/embedded placeholder is a malformed spec → rejected (no ambiguous substitution).
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.resolveArgv(
                ["gh", "--limit={limit}"], params: ["limit": "30"], sourceID: "s")
        }
        // A missing param → rejected (fail-closed).
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.resolveArgv(
                command, params: ["limit": "30"], sourceID: "s")
        }
        // A placeholder in argv[0] (the executable) is rejected — the page can never pick the executable.
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.resolveArgv(
                ["{exe}", "list"], params: ["exe": "rm"], sourceID: "s")
        }
    }

    @Test("resolveExecutable accepts absolute paths + bare names but rejects relative paths")
    func resolveExecutable() {
        #expect(WorkspaceAppGenericCLIReadClient.resolveExecutable("/bin/cat") == "/bin/cat")
        // Relative path (contains `/` but not absolute) is rejected — no cwd-relative resolution.
        #expect(WorkspaceAppGenericCLIReadClient.resolveExecutable("./evil") == nil)
        #expect(WorkspaceAppGenericCLIReadClient.resolveExecutable("../evil") == nil)
    }

    @Test("value validation enforces charset, length, and no leading dash")
    func valueValidation() {
        #expect(WorkspaceAppGenericCLIReadClient.isSafeValue("open"))
        #expect(WorkspaceAppGenericCLIReadClient.isSafeValue("2026-06-24"))
        #expect(WorkspaceAppGenericCLIReadClient.isSafeValue("owner/repo"))
        #expect(!WorkspaceAppGenericCLIReadClient.isSafeValue("-flag"))       // leading dash
        #expect(!WorkspaceAppGenericCLIReadClient.isSafeValue("a;b"))         // shell metachar
        #expect(!WorkspaceAppGenericCLIReadClient.isSafeValue("$(whoami)"))   // command substitution
        #expect(!WorkspaceAppGenericCLIReadClient.isSafeValue(String(repeating: "a", count: 300))) // too long
    }

    @Test("JSON output decodes to scalar rows (top-level + rowsPath), drops nested, caps to limit, fails closed on garbage")
    func decodeRows() throws {
        let top = try WorkspaceAppGenericCLIReadClient.decodeRows(
            from: #"[{"number":1,"title":"a","nested":{"x":1}},{"number":2,"title":"b"}]"#, rowsPath: nil, limit: 100, sourceID: "s")
        #expect(top.count == 2)
        #expect(top[0]["number"] == .integer(1))
        #expect(top[0]["title"] == .text("a"))
        #expect(top[0]["nested"] == nil)   // nested object dropped
        // rowsPath navigates into a wrapper object.
        let nested = try WorkspaceAppGenericCLIReadClient.decodeRows(
            from: #"{"data":{"items":[{"id":"x"}]}}"#, rowsPath: "data.items", limit: 100, sourceID: "s")
        #expect(nested == [["id": .text("x")]])
        // The row count is capped to the requested limit (a CLI that ignores {limit} can't over-read).
        let capped = try WorkspaceAppGenericCLIReadClient.decodeRows(
            from: #"[{"i":1},{"i":2},{"i":3}]"#, rowsPath: nil, limit: 2, sourceID: "s")
        #expect(capped.count == 2)
        // Garbage / non-array FAILS CLOSED (throws), never "looks like no rows".
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.decodeRows(from: "not json", rowsPath: nil, limit: 100, sourceID: "s")
        }
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.decodeRows(from: #"{"not":"an array"}"#, rowsPath: nil, limit: 100, sourceID: "s")
        }
    }

    @Test("the generic client runs a cli read via the runner and fails closed for http/mcp + unknown op")
    func genericClientReadAndFailClosed() async throws {
        let exec = WorkspaceAppCapabilityReadExecution(
            transport: .cli,
            operations: ["default": .init(command: ["gh", "issue", "list", "--limit", "{limit}"], rowsPath: nil)]
        )
        let cwd = NSTemporaryDirectory()   // a real directory — read() fails closed without one
        let client = WorkspaceAppGenericCLIReadClient(runner: FakeCLIRunner(json: #"[{"number":7,"title":"hi"}]"#))
        let rows = try await client.read(execution: exec, operation: "default", sourceID: "s",
                                         workspacePath: cwd, input: WorkspaceAppSourceResolutionInput(limit: 5))
        #expect(rows == [["number": .integer(7), "title": .text("hi")]])

        // A non-zero exit FAILS CLOSED (auth/network/CLI failure must not look like "no rows").
        let failing = WorkspaceAppGenericCLIReadClient(runner: FakeCLIRunner(json: "", exitCode: 1))
        await #expect(throws: (any Error).self) {
            _ = try await failing.read(execution: exec, operation: "default", sourceID: "s",
                                       workspacePath: cwd, input: WorkspaceAppSourceResolutionInput())
        }
        // A missing workspace directory FAILS CLOSED (never inherit ASTRA's cwd).
        await #expect(throws: (any Error).self) {
            _ = try await client.read(execution: exec, operation: "default", sourceID: "s",
                                      workspacePath: "", input: WorkspaceAppSourceResolutionInput())
        }
        // Unknown operation → fail-closed.
        await #expect(throws: (any Error).self) {
            _ = try await client.read(execution: exec, operation: "nope", sourceID: "s",
                                      workspacePath: cwd, input: WorkspaceAppSourceResolutionInput())
        }
        // http transport is accepted in the schema but not executable → fail-closed.
        let httpExec = WorkspaceAppCapabilityReadExecution(transport: .http, operations: ["default": .init(command: ["x"], rowsPath: nil)])
        await #expect(throws: (any Error).self) {
            _ = try await client.read(execution: httpExec, operation: "default", sourceID: "s",
                                      workspacePath: cwd, input: WorkspaceAppSourceResolutionInput())
        }
    }

    // MARK: - End-to-end: enable → publish-binding → resolve → generic read

    @Test("resolveCapabilityReadAsync runs a capability-contributed generic read end to end")
    func endToEndGenericRead() async throws {
        let (families, impls) = WorkspaceAppCapabilityContractDeriver.derived(from: [capabilityPackage()])
        let familyID = families[0].id
        let impl = impls[0]
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gen-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Caps", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "issues-app", name: "Issues"),
            requirements: [WorkspaceAppRequirement(id: "mycap", contract: familyID, operations: ["default"], providerHint: "cli")],
            sources: [WorkspaceAppSource(id: "issues", requirementRef: "mycap", operation: "default", mode: "read")],
            actions: [WorkspaceAppActionSpec(id: "read_issues", type: "capability.read", sourceRef: "issues")],
            permissions: WorkspaceAppPermissions(reads: [familyID], defaultMode: .draftOnly)
        )
        let app = WorkspaceApp(
            workspaceID: workspace.id, logicalID: manifest.app.id, name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id, appID: app.id, appLogicalID: app.logicalID,
            requirementID: "mycap", contract: familyID, operations: ["default"], optional: false,
            status: .mapped, implementationID: impl.id, provider: "cli", transport: .cli
        )

        var resolver = WorkspaceAppSourceResolver()
        resolver.capabilityImplementations = { _ in impls }   // inject (no filesystem)
        resolver.genericCLIReadClient = WorkspaceAppGenericCLIReadClient(
            runner: FakeCLIRunner(json: #"[{"number":42,"title":"Live"}]"#))

        let resolved = try await resolver.resolveCapabilityReadAsync(
            sourceID: "issues", app: app, workspace: workspace, manifest: manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppSourceResolutionInput(limit: 30, parameters: ["state": .text("open")]))

        #expect(resolved.rows == [["number": .integer(42), "title": .text("Live")]])
        #expect(resolved.implementationID == impl.id)
        #expect(resolved.provider == "cli")
    }

    // MARK: - FU1: per-param value schema (enum / regex / fixed)

    @Test("the deriver parses inline param constraints into bare {name} tokens + a constraint map")
    func deriverParsesParamConstraints() {
        let (cmd, params) = WorkspaceAppCapabilityContractDeriver.parseCommandTokens(
            ["--state", "{state:enum=open,closed,all}", "--repo", "{repo:fixed=owner/x}", "--n", "{n:re=^[0-9]+$}", "{plain}"])
        #expect(cmd == ["--state", "{state}", "--repo", "{repo}", "--n", "{n}", "{plain}"])
        #expect(params["state"]?.allowed == ["open", "closed", "all"])
        #expect(params["repo"]?.fixed == "owner/x")
        #expect(params["n"]?.pattern == "^[0-9]+$")
        #expect(params["plain"] == nil)   // bare placeholder ⇒ base guard only
    }

    @Test("the client enforces fixed/enum/regex param constraints (the page can't override a fixed value)")
    func paramConstraintsEnforced() throws {
        let constraints: [String: WorkspaceAppCapabilityReadExecution.ParamConstraint] = [
            "repo": .init(fixed: "owner/x"),
            "state": .init(allowed: ["open", "closed"]),
            "n": .init(pattern: "^[0-9]+$"),
        ]
        let command = ["gh", "--repo", "{repo}", "--state", "{state}", "--n", "{n}"]
        // fixed: the page's value for {repo} is IGNORED — the author's pinned value wins.
        let argv = try WorkspaceAppGenericCLIReadClient.resolveArgv(
            command, params: ["repo": "attacker/evil", "state": "open", "n": "42"], constraints: constraints, sourceID: "s")
        #expect(argv == ["gh", "--repo", "owner/x", "--state", "open", "--n", "42"])
        // enum: a value outside the allowed set is rejected.
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.resolveArgv(
                command, params: ["state": "merged", "n": "42"], constraints: constraints, sourceID: "s")
        }
        // regex: a value that doesn't match the whole pattern is rejected.
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAppGenericCLIReadClient.resolveArgv(
                command, params: ["state": "open", "n": "4a2"], constraints: constraints, sourceID: "s")
        }
    }

    @Test("matchesWholeValue anchors over the whole value and fails closed on an over-long author pattern")
    func patternMatchingIsWholeValueAndLengthBounded() {
        // whole-extent: a pattern that only matches a PREFIX is not a match.
        #expect(WorkspaceAppGenericCLIReadClient.matchesWholeValue("12345", pattern: "^[0-9]+$"))
        #expect(!WorkspaceAppGenericCLIReadClient.matchesWholeValue("123x", pattern: "^[0-9]+$"))
        #expect(!WorkspaceAppGenericCLIReadClient.matchesWholeValue("x", pattern: "(["))   // invalid → false
        // FU1 LOW: an over-long author pattern is rejected before compilation (cheap ReDoS insurance).
        let huge = "(a|b)" + String(repeating: "?", count: WorkspaceAppGenericCLIReadClient.maxPatternLength)
        #expect(!WorkspaceAppGenericCLIReadClient.matchesWholeValue("a", pattern: huge))
    }

    // MARK: - FU3: app-scoped connector-read rate budget

    @Test("the rate limiter bounds reads per app over a sliding window, per-app and time-expiring")
    func rateLimiterBoundsReads() {
        let limiter = WorkspaceAppConnectorReadRateLimiter(maxPerWindow: 2, window: 60)
        let app = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(limiter.admit(appID: app, now: t0))
        #expect(limiter.admit(appID: app, now: t0.addingTimeInterval(1)))
        #expect(!limiter.admit(appID: app, now: t0.addingTimeInterval(2)))   // over budget in-window
        // After the window slides past the early reads, the app is admitted again.
        #expect(limiter.admit(appID: app, now: t0.addingTimeInterval(62)))
        // A different app has its own independent budget.
        #expect(limiter.admit(appID: UUID(), now: t0.addingTimeInterval(2)))
    }

    // MARK: - Real process (gated): proves the hardened runner actually spawns + decodes

    @Test("the REAL hardened runner spawns a process and decodes its JSON output",
          .enabled(if: ProcessInfo.processInfo.environment["RUN_REAL_PROVIDERS"] == "1"))
    func realHardenedRunnerExecutes() async throws {
        // `/bin/cat <tmpfile>` is always present, local, and instant — it prints the JSON we wrote,
        // proving the real Process path (no shell, argv array, drained pipes, decode) without any network
        // or gh dep. (We feed the JSON via a temp FILE because author command args may not contain `{}` —
        // those are reserved for placeholders.)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gen-real-\(UUID().uuidString).json")
        try #"[{"number":1,"title":"real"}]"#.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let exec = WorkspaceAppCapabilityReadExecution(
            transport: .cli,
            operations: ["default": .init(command: ["/bin/cat", file.path], rowsPath: nil)]
        )
        let rows = try await WorkspaceAppGenericCLIReadClient().read(
            execution: exec, operation: "default", sourceID: "s",
            workspacePath: NSTemporaryDirectory(), input: WorkspaceAppSourceResolutionInput(limit: 1))
        #expect(rows == [["number": .integer(1), "title": .text("real")]])
    }
}

/// A fake CLI runner that returns canned JSON + exit code without spawning a process — keeps the suite
/// hermetic.
private struct FakeCLIRunner: WorkspaceAppCLIReadRunning {
    let json: String
    var exitCode: Int32 = 0
    func run(executablePath: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) async throws -> WorkspaceAppCLIReadResult {
        WorkspaceAppCLIReadResult(stdout: json, exitCode: exitCode)
    }
}
