import Foundation
import Darwin
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Execution Sandbox")
struct ExecutionSandboxTests {

    // MARK: - Helpers

    private func makePlan(
        runtime: AgentRuntimeID = .claudeCode,
        executablePath: String = "/usr/local/bin/claude",
        arguments: [String] = ["--print", "do work"],
        currentDirectory: String = "/tmp/astra-workspace",
        environment: [String: String] = ["HOME": "/tmp/astra-home"],
        directoriesToCreate: [String] = []
    ) -> AgentRuntimeProcessLaunchPlan {
        AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: true,
            directoriesToCreate: directoriesToCreate,
            providerDetectedFields: [:],
            commandPlannedFields: [:]
        )
    }

    // MARK: - Enforcement parsing

    @Test("Enforcement parsing defaults unknown values to best effort")
    func enforcementParsing() {
        #expect(ExecutionSandboxEnforcement.normalized(nil) == .bestEffort)
        #expect(ExecutionSandboxEnforcement.normalized("off") == .off)
        #expect(ExecutionSandboxEnforcement.normalized("disabled") == .off)
        #expect(ExecutionSandboxEnforcement.normalized("strict") == .strict)
        #expect(ExecutionSandboxEnforcement.normalized("best-effort") == .bestEffort)
        #expect(ExecutionSandboxEnforcement.normalized("nonsense") == .bestEffort)
    }

    // MARK: - Profile generation

    @Test("Profile denies writes then re-allows one param per writable root")
    func profileShape() {
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 3, allowNetwork: true)
        #expect(profile.contains("(allow default)"))
        #expect(profile.contains("(deny file-write*)"))
        #expect(profile.contains("(subpath (param \"ROOT_0\"))"))
        #expect(profile.contains("(subpath (param \"ROOT_1\"))"))
        #expect(profile.contains("(subpath (param \"ROOT_2\"))"))
        #expect(!profile.contains("ROOT_3"))
        #expect(profile.contains("(subpath \"/dev\")"))
        // Network allowed by default -> no network deny line.
        #expect(!profile.contains("(deny network*)"))
    }

    @Test("Offline profile denies network")
    func offlineProfile() {
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: false)
        #expect(profile.contains("(deny network*)"))
    }

    // MARK: - Argument assembly

    @Test("Arguments pass paths as -D params, never interpolated into the profile")
    func argumentAssembly() {
        // A path containing characters that would break a naively interpolated
        // profile: a space, a quote, and a paren.
        let nastyRoot = "/tmp/weird (dir) \"name\""
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)
        let args = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: [nastyRoot],
            executablePath: "/bin/echo",
            arguments: ["hello", "world"]
        )

        #expect(args[0] == "-p")
        #expect(args[1] == profile)
        #expect(args.contains("-D"))
        #expect(args.contains("ROOT_0=\(nastyRoot)"))

        // The raw path must not appear inside the profile string itself.
        #expect(!profile.contains(nastyRoot))

        // The real command + args come last, in order.
        let echoIndex = args.firstIndex(of: "/bin/echo")
        #expect(echoIndex != nil)
        if let echoIndex {
            #expect(args[echoIndex...] == ["/bin/echo", "hello", "world"])
        }
    }

    // MARK: - Canonicalization

    @Test("Canonicalize expands tilde, normalizes firmlinks, and rejects empty")
    func canonicalization() {
        #expect(ExecutionSandbox.canonicalize("") == nil)
        #expect(ExecutionSandbox.canonicalize("   ") == nil)
        #expect(ExecutionSandbox.canonicalize("/tmp") == "/private/tmp")
        #expect(ExecutionSandbox.canonicalize("/tmp/foo") == "/private/tmp/foo")
        // A /private path is left intact (no double prefix).
        #expect(ExecutionSandbox.canonicalize("/private/tmp/foo") == "/private/tmp/foo")
        let home = ExecutionSandbox.canonicalize("~")
        #expect(home != nil)
        #expect(home?.hasPrefix("/") == true)
    }

    // MARK: - Writable roots

    @Test("Writable roots include workspace, provider home, and temp; deduped")
    func writableRoots() {
        let plan = makePlan(
            currentDirectory: "/tmp/astra-workspace",
            environment: ["HOME": "/tmp/astra-home", "TMPDIR": "/tmp"],
            directoriesToCreate: ["/tmp/astra-workspace/.astra/tasks/ab"]
        )
        let workspace = ExecutionSandbox.canonicalize(plan.currentDirectory)!
        let roots = ExecutionSandbox.writableRoots(
            plan: plan,
            providerHomeDirectory: "",
            canonicalWorkspace: workspace
        )
        #expect(roots.contains(workspace))
        #expect(roots.contains("/private/tmp/astra-workspace/.astra/tasks/ab"))
        #expect(roots.contains("/private/tmp/astra-home/.claude"))
        #expect(roots.contains("/private/tmp")) // TMPDIR + "/tmp" both canonicalize here
        // No duplicates.
        #expect(roots.count == Set(roots).count)
    }

    // MARK: - Decision logic

    @Test("Disabled enforcement skips wrapping")
    func decisionDisabled() {
        let decision = ExecutionSandbox.decide(
            plan: makePlan(),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .off)
        )
        #expect(decision == .skipped(reason: "disabled"))
    }

    @Test("Self-sandboxing runtimes are excluded by default")
    func decisionExcludedRuntime() {
        let decision = ExecutionSandbox.decide(
            plan: makePlan(runtime: .codexCLI),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .strict)
        )
        #expect(decision == .skipped(reason: "runtime_excluded"))
    }

    @Test("Strict enforcement fails closed when there is no execution path")
    func decisionFailClosed() {
        let decision = ExecutionSandbox.decide(
            plan: makePlan(currentDirectory: ""),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .strict)
        )
        #expect(decision == .failClosed(reason: "no_execution_path"))
    }

    @Test("Best-effort enforcement falls back when there is no execution path")
    func decisionFallback() {
        let decision = ExecutionSandbox.decide(
            plan: makePlan(currentDirectory: ""),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .bestEffort)
        )
        #expect(decision == .fallback(reason: "no_execution_path"))
    }

    @Test("Applied decision rewrites the plan to launch via sandbox-exec")
    func decisionApplied() {
        guard FileManager.default.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let plan = makePlan(arguments: ["--print", "do work"])
        let decision = ExecutionSandbox.decide(
            plan: plan,
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .bestEffort)
        )
        guard case .applied(let wrapped, let roots) = decision else {
            Issue.record("Expected .applied, got \(decision)")
            return
        }
        #expect(wrapped.executablePath == ExecutionSandbox.sandboxExecPath)
        #expect(wrapped.currentDirectory == plan.currentDirectory)
        #expect(wrapped.environment == plan.environment)
        #expect(wrapped.runtime == plan.runtime)
        // Original executable + args preserved at the tail.
        #expect(wrapped.arguments.contains(plan.executablePath))
        if let execIndex = wrapped.arguments.firstIndex(of: plan.executablePath) {
            #expect(Array(wrapped.arguments[execIndex...]) == [plan.executablePath, "--print", "do work"])
        }
        #expect(!roots.isEmpty)
    }

    // MARK: - Persisted settings resolution

    @Test("current() honors enforcement, network, and layering defaults")
    func currentSettingsResolution() {
        let suiteName = "astra-sandbox-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset defaults: best effort, network allowed, no native layering.
        let base = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)
        #expect(base.enforcement == .bestEffort)
        #expect(base.allowNetwork == true)
        #expect(base.shouldWrap(runtime: .claudeCode))
        #expect(base.shouldWrap(runtime: .copilotCLI))
        #expect(!base.shouldWrap(runtime: .codexCLI))

        // Autonomous escalates best-effort to strict.
        let auto = ExecutionSandboxSettings.current(permissionPolicy: .autonomous, defaults: defaults)
        #expect(auto.enforcement == .strict)

        // Offline + layering over self-sandboxing providers.
        defaults.set(ExecutionSandboxEnforcement.strict.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        defaults.set(false, forKey: AppStorageKeys.sandboxAllowNetwork)
        defaults.set(true, forKey: AppStorageKeys.sandboxLayerNativeProviders)
        let custom = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)
        #expect(custom.enforcement == .strict)
        #expect(custom.allowNetwork == false)
        #expect(custom.shouldWrap(runtime: .claudeCode))
        #expect(custom.shouldWrap(runtime: .codexCLI))
        #expect(custom.shouldWrap(runtime: .cursorCLI))
        #expect(custom.shouldWrap(runtime: .antigravityCLI))

        // Off disables wrapping for every runtime.
        defaults.set(ExecutionSandboxEnforcement.off.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        let off = ExecutionSandboxSettings.current(permissionPolicy: .autonomous, defaults: defaults)
        #expect(off.enforcement == .off)
        #expect(!off.shouldWrap(runtime: .claudeCode))
        #expect(!off.shouldWrap(runtime: .codexCLI))
    }

    @Test("Offline settings produce a network-denying profile via decide")
    func offlineDecisionProducesNetworkDeny() {
        guard FileManager.default.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let decision = ExecutionSandbox.decide(
            plan: makePlan(),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .bestEffort, allowNetwork: false)
        )
        guard case .applied(let wrapped, _) = decision else {
            Issue.record("Expected .applied, got \(decision)")
            return
        }
        // The profile is the argument right after "-p".
        let profileIndex = wrapped.arguments.firstIndex(of: "-p").map { $0 + 1 }
        #expect(profileIndex != nil)
        if let profileIndex {
            #expect(wrapped.arguments[profileIndex].contains("(deny network*)"))
        }
    }

    // MARK: - Integration: real kernel boundary

    @Test("Seatbelt confines writes to the workspace and blocks escapes")
    func seatbeltEnforcesWriteBoundary() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let base = fm.temporaryDirectory.appendingPathComponent("astra-sandbox-test-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // Only the workspace is writable. `base` (its parent) deliberately is not.
        let workspaceRoot = ExecutionSandbox.canonicalize(workspace.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)

        let insidePath = workspace.appendingPathComponent("inside.txt").path
        let outsidePath = base.appendingPathComponent("outside.txt").path

        func runConfinedShell(_ script: String) -> Int32 {
            let args = ExecutionSandbox.makeArguments(
                profile: profile,
                writableRoots: [workspaceRoot],
                executablePath: "/bin/sh",
                arguments: ["-c", script]
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ExecutionSandbox.sandboxExecPath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Issue.record("Failed to launch sandbox-exec: \(error)")
                return -1
            }
            process.waitUntilExit()
            return process.terminationStatus
        }

        // Reads outside the workspace stay allowed (broad read).
        #expect(runConfinedShell("cat /etc/hosts > /dev/null") == 0)

        // Write inside the workspace succeeds.
        let insideStatus = runConfinedShell("printf astra > '\(insidePath)'")
        #expect(insideStatus == 0)
        #expect(fm.fileExists(atPath: insidePath))

        // Write outside the workspace is blocked by the kernel.
        let outsideStatus = runConfinedShell("printf escape > '\(outsidePath)'")
        #expect(outsideStatus != 0)
        #expect(!fm.fileExists(atPath: outsidePath))
    }

    // MARK: - Decision: unsafe / unavailable branches

    @Test("An overly broad workspace root is refused, not wrapped into a no-op sandbox")
    func decisionUnsafeWorkspaceRoot() {
        // `/` and top-level system roots would make most of the filesystem
        // writable; decide() must refuse them (the over-broad-root guard) rather
        // than emit .applied with ROOT_0=/.
        for broad in ["/", "/usr", "/Users", "/System", "/private/tmp"] {
            #expect(ExecutionSandbox.isOverlyBroadRoot(broad))

            let strict = ExecutionSandbox.decide(
                plan: makePlan(currentDirectory: broad),
                providerHomeDirectory: "",
                settings: ExecutionSandboxSettings(enforcement: .strict)
            )
            #expect(strict == .failClosed(reason: "unsafe_execution_path"))

            let best = ExecutionSandbox.decide(
                plan: makePlan(currentDirectory: broad),
                providerHomeDirectory: "",
                settings: ExecutionSandboxSettings(enforcement: .bestEffort)
            )
            #expect(best == .fallback(reason: "unsafe_execution_path"))
        }
        // A normal deep workspace is NOT considered broad.
        #expect(!ExecutionSandbox.isOverlyBroadRoot("/private/tmp/astra-workspace"))
    }

    @Test("Missing sandbox-exec fails closed under strict, falls back under best-effort")
    func decisionSandboxExecMissing() {
        let absent = StubExecutableFileManager(executableExists: false)

        let strict = ExecutionSandbox.decide(
            plan: makePlan(),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .strict),
            fileManager: absent
        )
        #expect(strict == .failClosed(reason: "sandbox_exec_missing"))

        let best = ExecutionSandbox.decide(
            plan: makePlan(),
            providerHomeDirectory: "",
            settings: ExecutionSandboxSettings(enforcement: .bestEffort),
            fileManager: absent
        )
        #expect(best == .fallback(reason: "sandbox_exec_missing"))
    }

    @Test("Every unavailable reason maps strict->failClosed and best-effort->fallback")
    func unavailableMappingAllReasons() {
        // no_execution_path: empty workspace.
        let emptyWorkspace = makePlan(currentDirectory: "")
        // unsafe_execution_path: root workspace.
        let broadWorkspace = makePlan(currentDirectory: "/")
        // sandbox_exec_missing: valid workspace but no sandbox-exec.
        let absent = StubExecutableFileManager(executableExists: false)

        let cases: [(reason: String, plan: AgentRuntimeProcessLaunchPlan, fm: FileManager)] = [
            ("no_execution_path", emptyWorkspace, .default),
            ("unsafe_execution_path", broadWorkspace, .default),
            ("sandbox_exec_missing", makePlan(), absent)
        ]

        for testCase in cases {
            let strict = ExecutionSandbox.decide(
                plan: testCase.plan,
                providerHomeDirectory: "",
                settings: ExecutionSandboxSettings(enforcement: .strict),
                fileManager: testCase.fm
            )
            #expect(strict == .failClosed(reason: testCase.reason))

            let best = ExecutionSandbox.decide(
                plan: testCase.plan,
                providerHomeDirectory: "",
                settings: ExecutionSandboxSettings(enforcement: .bestEffort),
                fileManager: testCase.fm
            )
            #expect(best == .fallback(reason: testCase.reason))
        }
    }

    // MARK: - Runner: decision -> launch outcome mapping

    @Test("Runner blocks the run on failClosed and never falls through to running unconfined")
    func runnerSandboxOutcomeMapping() {
        let original = makePlan()
        let wrapped = makePlan(executablePath: ExecutionSandbox.sandboxExecPath)

        // applied -> run the wrapped (sandbox-exec) plan.
        if case .plan(let p) = AgentRuntimeProcessRunner.sandboxOutcome(
            for: .applied(plan: wrapped, writableRoots: ["/private/tmp/x"]),
            originalPlan: original
        ) {
            #expect(p.executablePath == ExecutionSandbox.sandboxExecPath)
        } else {
            Issue.record("applied should map to .plan(wrapped)")
        }

        // skipped / fallback -> run the ORIGINAL plan unchanged (unconfined).
        for decision: ExecutionSandboxDecision in [.skipped(reason: "disabled"), .fallback(reason: "x")] {
            if case .plan(let p) = AgentRuntimeProcessRunner.sandboxOutcome(for: decision, originalPlan: original) {
                #expect(p.executablePath == original.executablePath)
            } else {
                Issue.record("\(decision) should map to .plan(original)")
            }
        }

        // failClosed -> BLOCK: a fail-closed AgentProcessResult, never a plan.
        if case .blocked(let result) = AgentRuntimeProcessRunner.sandboxOutcome(
            for: .failClosed(reason: "sandbox_exec_missing"),
            originalPlan: original
        ) {
            #expect(result.exitCode == -1)
            #expect(result.runtimeStopReason == "sandbox_unavailable")
        } else {
            Issue.record("failClosed MUST map to .blocked, never .plan — a regression here runs unconfined")
        }
    }

    // MARK: - Integration: real kernel boundary, hardened cases

    @Test("Seatbelt confines a workspace path containing spaces, quotes, and parens")
    func seatbeltConfinesNastyPath() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        // A real workspace whose name would break a naively-interpolated profile.
        // This is the value flowing through `-D ROOT_0=...`; the test proves the
        // KERNEL actually honors it, not just that the arg vector contains it.
        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("weird (dir) \"q\"")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let root = ExecutionSandbox.canonicalize(workspace.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)
        let insidePath = workspace.appendingPathComponent("inside.txt").path
        let outsidePath = base.appendingPathComponent("outside.txt").path

        let insideStatus = runConfined(profile: profile, writableRoots: [root], script: "printf astra > '\(insidePath)'")
        #expect(insideStatus == 0)
        #expect(fm.fileExists(atPath: insidePath))

        let outsideStatus = runConfined(profile: profile, writableRoots: [root], script: "printf escape > '\(outsidePath)'")
        #expect(outsideStatus != 0)
        #expect(!fm.fileExists(atPath: outsidePath))
    }

    @Test("Seatbelt blocks writes through a symlink that escapes the workspace")
    func seatbeltBlocksSymlinkEscape() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // A symlink INSIDE the writable workspace pointing OUT of every root.
        let link = workspace.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        let root = ExecutionSandbox.canonicalize(workspace.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)
        let escapedPath = link.appendingPathComponent("escaped.txt").path
        let realEscapedPath = outside.appendingPathComponent("escaped.txt").path

        // The kernel resolves the real path (outside) and must deny the write.
        let status = runConfined(profile: profile, writableRoots: [root], script: "printf pwned > '\(escapedPath)'")
        #expect(status != 0)
        #expect(!fm.fileExists(atPath: realEscapedPath))
    }

    @Test("Seatbelt blocks unlink and chmod of files outside the workspace")
    func seatbeltBlocksAdditionalEscapePrimitives() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let outsideFile = base.appendingPathComponent("victim.txt")
        try "keep".write(to: outsideFile, atomically: true, encoding: .utf8)

        let root = ExecutionSandbox.canonicalize(workspace.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)

        // unlink (file-write-unlink) outside the allowlist is denied.
        let rmStatus = runConfined(profile: profile, writableRoots: [root], script: "rm -f '\(outsideFile.path)'")
        #expect(rmStatus != 0)
        #expect(fm.fileExists(atPath: outsideFile.path))

        // chmod (file-write-mode) outside the allowlist is denied.
        let chmodStatus = runConfined(profile: profile, writableRoots: [root], script: "chmod 777 '\(outsideFile.path)'")
        #expect(chmodStatus != 0)
    }

    @Test("Offline profile blocks an outbound connection that the online profile allows")
    func seatbeltOfflineProfileBlocksNetwork() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath),
              fm.isExecutableFile(atPath: "/bin/bash") else { return }

        // A loopback listener we control, so the connect target is real and the
        // only variable is the sandbox profile.
        guard let listener = makeLoopbackListener() else { return }
        defer { close(listener.fd) }

        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = ExecutionSandbox.canonicalize(base.path)!

        // bash /dev/tcp triggers a real network-outbound operation.
        let connect = "exec 3<>/dev/tcp/127.0.0.1/\(listener.port)"
        func runConnect(allowNetwork: Bool) -> Int32 {
            let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: allowNetwork)
            return runConfined(profile: profile, writableRoots: [root], executablePath: "/bin/bash", script: connect)
        }

        // Establish a baseline: if the online connect doesn't succeed (e.g. this
        // bash lacks /dev/tcp), the mechanism is unavailable — skip rather than
        // assert a flaky result.
        guard runConnect(allowNetwork: true) == 0 else { return }

        // With (deny network*) the same connect must be blocked by the kernel.
        #expect(runConnect(allowNetwork: false) != 0)
    }

    @Test("Decide()'s own assembled plan, run through the kernel, confines writes (single + multi root)")
    func seatbeltAppliedPlanFromDecideEnforcesBoundary() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        let taskDir = base.appendingPathComponent("taskdir")   // a second root via directoriesToCreate
        let denied = base.appendingPathComponent("denied")     // not in any root
        for dir in [workspace, taskDir, denied] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }

        // Build the wrapped plan via the REAL decide() path (not a hand-built
        // profile), so this proves the assembled `-p`/`-D` argument vector works.
        func wrappedPlan(script: String) -> AgentRuntimeProcessLaunchPlan? {
            let plan = makePlan(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                currentDirectory: workspace.path,
                environment: ["HOME": base.appendingPathComponent("home").path],
                directoriesToCreate: [taskDir.path]
            )
            guard case .applied(let wrapped, _) = ExecutionSandbox.decide(
                plan: plan,
                providerHomeDirectory: "",
                settings: ExecutionSandboxSettings(enforcement: .bestEffort)
            ) else { return nil }
            return wrapped
        }

        let wsFile = workspace.appendingPathComponent("a.txt").path
        let taskFile = taskDir.appendingPathComponent("b.txt").path
        let deniedFile = denied.appendingPathComponent("c.txt").path

        guard let wsPlan = wrappedPlan(script: "printf x > '\(wsFile)'"),
              let taskPlan = wrappedPlan(script: "printf x > '\(taskFile)'"),
              let deniedPlan = wrappedPlan(script: "printf x > '\(deniedFile)'") else {
            Issue.record("decide() should return .applied")
            return
        }

        #expect(runWrappedPlan(wsPlan) == 0)
        #expect(fm.fileExists(atPath: wsFile))
        #expect(runWrappedPlan(taskPlan) == 0)
        #expect(fm.fileExists(atPath: taskFile))
        #expect(runWrappedPlan(deniedPlan) != 0)
        #expect(!fm.fileExists(atPath: deniedFile))
    }

    @Test("/dev stays writable under the profile (provider shells need null/pty devices)")
    func seatbeltAllowsDevNull() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = ExecutionSandbox.canonicalize(base.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)
        #expect(runConfined(profile: profile, writableRoots: [root], script: "printf x > /dev/null") == 0)
    }

    @Test("Reads outside the workspace stay allowed by design (write-scoping, not read-scoping)")
    func seatbeltBroadReadIsByDesign() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // A "secret" outside every writable root. The boundary is write-only, so
        // reading it MUST still succeed — this pins the documented threat model
        // (no read-confinement; exfil-via-read is out of scope by design).
        let secret = base.appendingPathComponent("secret.txt")
        try "topsecret".write(to: secret, atomically: true, encoding: .utf8)

        let root = ExecutionSandbox.canonicalize(workspace.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)
        // Capture stdout and assert the secret's CONTENT came through — proving the
        // read genuinely succeeded, not just that `cat` exited 0 for some other
        // reason. (The profile only denies writes, so reads are open by design.)
        let result = runConfinedCapturingStdout(profile: profile, writableRoots: [root], script: "cat '\(secret.path)'")
        #expect(result.status == 0)
        #expect(result.stdout == "topsecret")
    }

    @Test("A workspace reached via a symlink still confines writes correctly")
    func seatbeltSymlinkedWorkspaceWritesSucceed() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let base = fm.temporaryDirectory.appendingPathComponent("astra-sbx-\(UUID().uuidString)")
        let realWorkspace = base.appendingPathComponent("real")
        try fm.createDirectory(at: realWorkspace, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: realWorkspace)
        defer { try? fm.removeItem(at: base) }

        // canonicalize resolves the symlink to the real path, which becomes the
        // root; a write via the symlink path must still be allowed.
        let root = ExecutionSandbox.canonicalize(link.path)!
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 1, allowNetwork: true)
        let viaLink = link.appendingPathComponent("f.txt").path
        let real = realWorkspace.appendingPathComponent("f.txt").path
        #expect(runConfined(profile: profile, writableRoots: [root], script: "printf x > '\(viaLink)'") == 0)
        #expect(fm.fileExists(atPath: real))
    }

    // MARK: - Canonicalization edge cases

    @Test("canonicalize rejects relative and newline-bearing paths")
    func canonicalizeRejectsRelativeAndNewline() {
        #expect(ExecutionSandbox.canonicalize("relative/dir") == nil)
        #expect(ExecutionSandbox.canonicalize("./foo") == nil)
        #expect(ExecutionSandbox.canonicalize("foo") == nil)
        #expect(ExecutionSandbox.canonicalize("/private/tmp/a\nb") == nil)
        // An absolute path is still accepted.
        #expect(ExecutionSandbox.canonicalize("/private/tmp/foo") == "/private/tmp/foo")
    }

    @Test("canonicalize collapses .. and strips trailing slashes so a grant can't widen")
    func canonicalizeDotDotAndTrailingSlash() {
        let dotdot = ExecutionSandbox.canonicalize("/private/tmp/ws/../out")
        #expect(dotdot != nil)
        #expect(dotdot?.contains("..") == false)
        #expect(ExecutionSandbox.canonicalize("/private/tmp/foo/")?.hasSuffix("/foo") == true)
    }

    @Test("canonicalize normalizes the /var firmlink (real TMPDIR location) to /private/var")
    func canonicalizeVarFoldersFirmlink() {
        #expect(ExecutionSandbox.canonicalize("/var/folders/ab/cd/T") == "/private/var/folders/ab/cd/T")
    }

    // MARK: - Writable roots edge cases

    @Test("effectiveHome precedence: provider home > env HOME > process home")
    func writableRootsEffectiveHomePrecedence() {
        let ws = ExecutionSandbox.canonicalize("/tmp/ws")!
        let planEnvHome = makePlan(environment: ["HOME": "/tmp/envhome"])

        // Provider home wins over env HOME for the config dotdirs.
        let withProvider = ExecutionSandbox.writableRoots(
            plan: planEnvHome, providerHomeDirectory: "/tmp/providerhome", canonicalWorkspace: ws
        )
        #expect(withProvider.contains("/private/tmp/providerhome/.claude"))
        #expect(!withProvider.contains("/private/tmp/envhome/.claude"))

        // Env HOME used when there is no provider home.
        let envOnly = ExecutionSandbox.writableRoots(
            plan: planEnvHome, providerHomeDirectory: "", canonicalWorkspace: ws
        )
        #expect(envOnly.contains("/private/tmp/envhome/.claude"))

        // Process home (NSHomeDirectory) when neither is set.
        let planNoHome = makePlan(environment: [:])
        let processHome = ExecutionSandbox.writableRoots(
            plan: planNoHome, providerHomeDirectory: "", canonicalWorkspace: ws
        )
        let expected = ExecutionSandbox.canonicalize((NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
        #expect(expected != nil)
        if let expected { #expect(processHome.contains(expected)) }
    }

    @Test("/private/tmp is always a writable root, even with no TMPDIR set")
    func writableRootsAlwaysIncludesTmp() {
        let ws = ExecutionSandbox.canonicalize("/tmp/ws")!
        let plan = makePlan(environment: ["HOME": "/tmp/h"]) // no TMPDIR
        let roots = ExecutionSandbox.writableRoots(plan: plan, providerHomeDirectory: "", canonicalWorkspace: ws)
        #expect(roots.contains("/private/tmp"))
    }

    @Test("Overly broad roots (e.g. a provider home or TMPDIR of '/') are dropped from the allowlist")
    func writableRootsExcludeOverlyBroadSources() {
        let ws = ExecutionSandbox.canonicalize("/tmp/ws")!
        let plan = makePlan(
            currentDirectory: "/tmp/ws",
            environment: ["HOME": "/tmp/h", "TMPDIR": "/"],          // broad TMPDIR
            directoriesToCreate: ["/", "/usr"]                       // broad dirs-to-create
        )
        let roots = ExecutionSandbox.writableRoots(
            plan: plan,
            providerHomeDirectory: "/",                              // broad provider home
            canonicalWorkspace: ws
        )
        // None of the filesystem-spanning roots leak in...
        #expect(!roots.contains("/"))
        #expect(!roots.contains("/usr"))
        #expect(!roots.contains("/private/var"))
        #expect(roots.allSatisfy { !ExecutionSandbox.isForbiddenWritableRoot($0) })
        // ...but the legitimate workspace and the shared temp root remain.
        #expect(roots.contains(ws))
        #expect(roots.contains("/private/tmp"))
        // A provider home of "/" yields no junk "/.claude" top-level roots.
        #expect(!roots.contains("/.claude"))
    }

    @Test("directoriesToCreate entries become writable roots even when outside the workspace")
    func writableRootsDirectoriesToCreate() {
        let ws = ExecutionSandbox.canonicalize("/tmp/ws")!
        let plan = makePlan(
            currentDirectory: "/tmp/ws",
            environment: ["HOME": "/tmp/h"],
            directoriesToCreate: ["/tmp/other/task"]
        )
        let roots = ExecutionSandbox.writableRoots(plan: plan, providerHomeDirectory: "", canonicalWorkspace: ws)
        #expect(roots.contains("/private/tmp/other/task"))
    }

    // MARK: - Profile edge cases

    @Test("makeProfile(0) is a valid all-writes-denied profile with only the /dev allow")
    func profileZeroRoots() {
        let profile = ExecutionSandbox.makeProfile(writableRootCount: 0, allowNetwork: true)
        #expect(profile.contains("(deny file-write*)"))
        #expect(!profile.contains("ROOT_0"))
        #expect(profile.contains("(subpath \"/dev\")"))
    }

    // MARK: - Settings resolution edge cases

    private func freshDefaults() -> (UserDefaults, String) {
        let suiteName = "astra-sandbox-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test("Strict stays strict under autonomous (escalation is a no-op when already strict)")
    func settingsStrictAutonomousNoOp() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ExecutionSandboxEnforcement.strict.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        let resolved = ExecutionSandboxSettings.current(permissionPolicy: .autonomous, defaults: defaults)
        #expect(resolved.enforcement == .strict)
    }

    @Test("shouldWrap matrix: only no-native-sandbox runtimes wrap, and never when off")
    func settingsShouldWrapMatrix() {
        let all: [AgentRuntimeID] = [.claudeCode, .copilotCLI, .codexCLI, .cursorCLI, .antigravityCLI]
        let wrappedByDefault: Set<AgentRuntimeID> = ExecutionSandboxSettings.defaultWrappedRuntimes
        for enforcement in [ExecutionSandboxEnforcement.off, .bestEffort, .strict] {
            let settings = ExecutionSandboxSettings(enforcement: enforcement) // no layering
            for runtime in all {
                let expected = enforcement != .off && wrappedByDefault.contains(runtime)
                #expect(settings.shouldWrap(runtime: runtime) == expected)
            }
        }
    }

    @Test("allowNetwork: explicit Bool honored; corrupt non-Bool fails open to network-on")
    func settingsAllowNetworkResolution() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: AppStorageKeys.sandboxAllowNetwork)
        #expect(ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults).allowNetwork == true)

        defaults.set(false, forKey: AppStorageKeys.sandboxAllowNetwork)
        #expect(ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults).allowNetwork == false)

        // A corrupt/legacy non-Bool value fails open (network on) rather than
        // silently severing the CLI's model API.
        defaults.set("false", forKey: AppStorageKeys.sandboxAllowNetwork)
        #expect(ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults).allowNetwork == true)
    }

    @Test("Layering toggle alone extends wrapped runtimes without changing enforcement/network")
    func settingsLayeringOnlyIsolated() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.sandboxLayerNativeProviders)
        let resolved = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)
        #expect(resolved.enforcement == .bestEffort)
        #expect(resolved.allowNetwork == true)
        #expect(resolved.shouldWrap(runtime: .claudeCode))
        #expect(resolved.shouldWrap(runtime: .codexCLI))
        #expect(resolved.shouldWrap(runtime: .cursorCLI))
        #expect(resolved.shouldWrap(runtime: .antigravityCLI))
    }

    @Test("Sandbox default constants and current() resolution match documented values")
    func settingsDefaultsMatchDocumentedValues() {
        // Assert against independent LITERALS (not the constants themselves), so
        // these are non-circular: changing a constant, OR changing current() to
        // stop using it, trips this. SettingsView's @AppStorage declarations derive
        // from these same constants, so pinning the constants pins the UI defaults.
        #expect(ExecutionSandboxSettings.defaultEnforcement == .bestEffort)
        #expect(ExecutionSandboxSettings.defaultAllowNetwork == true)
        #expect(ExecutionSandboxSettings.defaultLayerNativeProviders == false)

        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolved = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)
        #expect(resolved.enforcement == .bestEffort)
        #expect(resolved.allowNetwork == true)
        #expect(!resolved.shouldWrap(runtime: .codexCLI)) // layering off by default
    }

    // MARK: - Confined-process helper

    /// Launches `executablePath` under `sandbox-exec` with the given profile and
    /// writable roots, returning the termination status. Output is discarded.
    private func runConfined(
        profile: String,
        writableRoots: [String],
        executablePath: String = "/bin/sh",
        script: String
    ) -> Int32 {
        let args = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: writableRoots,
            executablePath: executablePath,
            arguments: ["-c", script]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExecutionSandbox.sandboxExecPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("Failed to launch sandbox-exec: \(error)")
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Like `runConfined` but captures stdout, so a test can prove output actually
    /// flowed (not merely that the process exited 0).
    private func runConfinedCapturingStdout(
        profile: String,
        writableRoots: [String],
        script: String
    ) -> (status: Int32, stdout: String) {
        let args = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: writableRoots,
            executablePath: "/bin/sh",
            arguments: ["-c", script]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExecutionSandbox.sandboxExecPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("Failed to launch sandbox-exec: \(error)")
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Launches an already-wrapped plan (whose `executablePath` is `sandbox-exec`)
    /// exactly as the runner would, returning the termination status.
    private func runWrappedPlan(_ plan: AgentRuntimeProcessLaunchPlan) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("Failed to launch wrapped plan: \(error)")
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A `FileManager` whose `isExecutableFile` is forced, so the sandbox decision's
/// `sandbox_exec_missing` branch is testable on a machine that has sandbox-exec.
private final class StubExecutableFileManager: FileManager {
    let executableExists: Bool
    init(executableExists: Bool) {
        self.executableExists = executableExists
        super.init()
    }
    override func isExecutableFile(atPath path: String) -> Bool { executableExists }
}

/// Opens a listening TCP socket on an ephemeral 127.0.0.1 port and returns it.
/// The caller owns the fd and must `close` it. `connect` to this port succeeds
/// at the kernel level without an explicit `accept`, which is all the network
/// boundary test needs.
private func makeLoopbackListener() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }

    var boundAddr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &boundAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    guard named == 0 else { close(fd); return nil }

    return (fd, UInt16(bigEndian: boundAddr.sin_port))
}
