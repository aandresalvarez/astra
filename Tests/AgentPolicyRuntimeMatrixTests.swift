import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The runtime × policy-level contract. Each runtime's flag builder is tested on
/// its own elsewhere; this pins the whole grid so a change to the shared
/// resolver, a preset, or one adapter cannot silently move a level in another
/// runtime. What it protects:
///
/// - Only Auto renders the runtime's bypass flags, and always does.
/// - Ask and the legacy presets never carry a bypass flag, and keep the
///   provider's own sandbox switched on where the provider has one.
/// - Ask never hands a runtime write or shell grants it was not given.
@Suite("Policy runtime matrix")
struct AgentPolicyRuntimeMatrixTests {
    /// What each runtime must lead with for Auto.
    private static let autonomousFlags: [AgentRuntimeID: [String]] = [
        .claudeCode: ["--dangerously-skip-permissions"],
        .copilotCLI: ["--allow-all"],
        .antigravityCLI: ["--dangerously-skip-permissions"],
        .codexCLI: ["--dangerously-bypass-approvals-and-sandbox"],
        .cursorCLI: ["--force", "--sandbox", "disabled"],
        .openCodeCLI: ["--dangerously-skip-permissions"]
    ]

    /// Every spelling a provider uses to turn its own gate off.
    private static let bypassSpellings = [
        "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox",
        "--allow-all", "--yolo", "--force", "danger-full-access", "disabled"
    ]

    @Test("The matrix covers every registered runtime")
    func matrixCoversEveryRegisteredRuntime() {
        // A new runtime fails here until its Auto flags are declared above.
        #expect(Set(AgentRuntimeAdapterRegistry.runtimeIDs) == Set(Self.autonomousFlags.keys))
    }

    @Test("Auto renders the runtime's bypass flags and is the only broad level")
    func autonomousIsTheOnlyBroadLevel() {
        for (runtime, flags) in Self.autonomousFlags {
            for level in AgentPolicyLevel.allCases {
                let render = Self.render(runtime: runtime, level: level)
                if level == .autonomous {
                    #expect(Array(render.cliArgumentsSummary.prefix(flags.count)) == flags, "\(runtime.rawValue) Auto")
                    #expect(render.usesBroadProviderPermissions, "\(runtime.rawValue) Auto is broad")
                } else {
                    #expect(!render.usesBroadProviderPermissions, "\(runtime.rawValue) \(level.rawValue) is not broad")
                }
            }
        }
    }

    @Test("No level other than Auto carries a bypass flag")
    func onlyAutonomousCarriesBypassFlags() {
        for runtime in Self.autonomousFlags.keys {
            for level in AgentPolicyLevel.allCases where level != .autonomous {
                let args = Self.render(runtime: runtime, level: level).cliArgumentsSummary
                for spelling in Self.bypassSpellings {
                    #expect(
                        !args.contains { $0.contains(spelling) },
                        "\(runtime.rawValue) \(level.rawValue) must not carry \(spelling): \(args)"
                    )
                }
            }
        }
    }

    @Test("Providers with their own sandbox keep it on below Auto")
    func providerSandboxStaysOnBelowAuto() {
        for level in AgentPolicyLevel.allCases where level != .autonomous {
            let agy = Self.render(runtime: .antigravityCLI, level: level).cliArgumentsSummary
            #expect(agy == ["--sandbox"], "Antigravity \(level.rawValue)")

            let cursor = Self.render(runtime: .cursorCLI, level: level).cliArgumentsSummary
            #expect(Self.value(after: "--sandbox", in: cursor) == "enabled", "Cursor \(level.rawValue)")

            let codex = Self.render(runtime: .codexCLI, level: level).cliArgumentsSummary
            let mode = Self.value(after: "--sandbox", in: codex)
            #expect(mode == "read-only" || mode == "workspace-write", "Codex \(level.rawValue)")
            #expect(codex.contains(#"approval_policy="never""#), "Codex \(level.rawValue) pins approvals")
        }
    }

    @Test("Codex Ask can write the workspace and nothing wider; locked and Custom are read-only")
    func codexSandboxModePerLevel() {
        func mode(_ level: AgentPolicyLevel) -> String? {
            Self.value(after: "--sandbox", in: Self.render(runtime: .codexCLI, level: level).cliArgumentsSummary)
        }
        #expect(mode(.review) == "workspace-write")
        #expect(mode(.locked) == "read-only")
        #expect(mode(.custom) == "read-only")
    }

    @Test("Cursor Custom asks first; Ask does not leave the sandbox")
    func cursorCustomUsesAskMode() {
        let custom = Self.render(runtime: .cursorCLI, level: .custom).cliArgumentsSummary
        #expect(Self.value(after: "--mode", in: custom) == "ask")
        let review = Self.render(runtime: .cursorCLI, level: .review).cliArgumentsSummary
        #expect(!review.contains("--mode"))
    }

    @Test("Claude Ask leaves writes, shell and web to live approval")
    func claudeAskDefersGatedToolsToApproval() {
        let render = Self.render(runtime: .claudeCode, level: .review)
        #expect(!render.cliArgumentsSummary.contains("--dangerously-skip-permissions"))
        let preset = AgentPolicy.preset(.review)
        #expect(Set(preset.askFirstTools).isSuperset(of: ["Write", "Edit", "Bash", "WebFetch"]))
        #expect(Set(preset.allowedTools).isDisjoint(with: ["Write", "Edit", "MultiEdit", "Bash"]))
    }

    @Test("Copilot Ask and locked grant no write and no shell")
    func copilotAskGrantsNoWriteOrShell() {
        for level in [AgentPolicyLevel.locked, .review] {
            let args = Self.render(runtime: .copilotCLI, level: level).cliArgumentsSummary
            #expect(args.first == "--allow-tool", "Copilot \(level.rawValue)")
            #expect(!args.contains("write"), "Copilot \(level.rawValue) must not allow write")
            #expect(!args.contains { $0.hasPrefix("shell(") }, "Copilot \(level.rawValue) must not allow shell")
        }
    }

    @Test("Copilot grants widen with the level: Ask, then Build, then Network")
    func copilotGrantsWidenWithTheLevel() {
        func grants(_ level: AgentPolicyLevel) -> Set<String> {
            Set(Self.render(runtime: .copilotCLI, level: level).cliArgumentsSummary.dropFirst())
        }
        #expect(grants(.review).isStrictSubset(of: grants(.build)))
        #expect(grants(.build).isStrictSubset(of: grants(.network)))
    }

    // Ask asks before anything with an effect (docs/specs/2026-10-07-permission-levels-harmonization.md),
    // so a destructive or publishing command is a question, not a refusal, on
    // every runtime. `sudo` is the one exception: it cannot prompt in a
    // non-interactive run.
    @Test("Ask asks before destructive and publishing commands; sudo stays denied")
    func askAsksBeforeEffectsInsteadOfRefusing() {
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, level: .review))
            for command in ["rm -rf build", "git push origin main", "chmod +x script.sh"] {
                #expect(
                    guardrail.disposition(toolName: "Bash", command: command) == .ask,
                    "\(runtime.rawValue) Ask \(command)"
                )
            }
            #expect(guardrail.disposition(toolName: "Bash", command: "sudo ls") == .denied, "\(runtime.rawValue) sudo")
        }
    }

    // Local tools used to be pre-granted on Codex, Cursor, Antigravity and
    // OpenCode while Claude and Copilot asked for the same command, so Ask meant
    // a different thing per runtime. It now asks on every one.
    @Test("Ask pre-grants no local tool on any runtime; the build preset still does")
    func askPreGrantsNoLocalTool() {
        let tools = ["bq", "astra-browser"]
        for runtime in Self.autonomousFlags.keys {
            let ask = Self.render(runtime: runtime, level: .review, localToolCommands: tools)
            #expect(!ask.allowedShellPatterns.contains { $0.hasPrefix("bq") || $0.hasPrefix("astra-browser") }, "\(runtime.rawValue)")
            #expect(!ask.allowedTools.contains { $0.contains("bq") || $0.contains("astra-browser") }, "\(runtime.rawValue)")
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, level: .review, localToolCommands: tools))
            #expect(guardrail.disposition(toolName: "Bash", command: "astra-browser click --ref 12") == .ask, "\(runtime.rawValue)")
        }
        for runtime in [AgentRuntimeID.codexCLI, .cursorCLI, .antigravityCLI, .openCodeCLI] {
            let build = Self.render(runtime: runtime, level: .build, localToolCommands: tools)
            #expect(build.allowedShellPatterns.contains("bq *"), "\(runtime.rawValue) build")
        }
    }

    // Custom keeps the user's per-item rules for local work, but actions outside
    // ASTRA follow Ask: only a command made of listed local tools
    // (`LocalShellCommands`) runs on a rule alone, on every runtime. Whether a
    // command acts outside the machine is not read, so the cases below are
    // forms that once slipped past such a reading.
    @Test("Custom rules run only known local work unasked")
    func customRunsOnlyKnownLocalWorkUnasked() {
        let policy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["git:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: policy))
            #expect(guardrail.disposition(toolName: "Bash", command: "git status") == .allowed, "\(runtime.rawValue) local git")
            #expect(
                guardrail.disposition(toolName: "Bash", command: "git push origin main") == .ask,
                "\(runtime.rawValue) push"
            )
        }
        let wider = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: [
                "git:*", "curl:*", "gcloud:*", "gh:*", "npm:*", "aws:*", "kubectl:*", "wget:*", "docker:*", "psql:*", "mysql:*"
            ]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: wider))
            for command in [
                "curl -X POST https://hooks.example.test/build -d ok", "curl --json '{\"build\":1}' https://hooks.example.test/api",
                "curl -sSd ok https://hooks.example.test/build", "curl -dsecret https://hooks.example.test/build",
                "curl -K write.conf", "curl --data-ascii payload https://example.test/hook",
                "gcloud run deploy api --source .", "gh workflow run deploy.yml", "gh secret set TOKEN", "gh deploy",
                "gh api repos/o/r/issues/1/comments -fbody=hello", "npm unpublish widget@1.0.0", "npm token create",
                "npm --scope @foo publish", "npm --registry https://registry.example publish", "npm logout",
                "aws s3 cp report.csv s3://bucket/report.csv", "kubectl apply -f deploy.yaml --dry-run=none",
                "psql -c \"SELECT nextval('orders_id_seq')\"", "wget --method=POST --body-data=x https://hooks.example.test/build",
                "git send-pack git@github.com:owner/repo.git refs/heads/main", "git submodule foreach 'git push origin main'",
                "git rebase -x 'git push origin HEAD' main", "git difftool -x 'git push origin main' HEAD~1 HEAD",
                "docker --context production create alpine", "docker -H ssh://deploy@host rm web",
                "DOCKER_HOST=ssh://deploy@prod docker create alpine", "docker buildx build --push -t registry.example/app .",
                // Reads this list does not know are asked about too.
                "gcloud compute instances list", "kubectl get pods", "aws sts get-caller-identity", "psql -c 'SELECT 1'"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in [
                "curl https://example.test/status", "git commit -m wip", "gh workflow list", "gh run view 12345",
                "npm install", "curl -sSL https://example.test/status", "curl -sSLo status.json https://example.test/status",
                "npm install publish", "gh status", "gh -R owner/repo pr list", "git submodule update --init",
                "wget https://example.test/status", "curl -X GET https://example.test/status",
                "curl --request=GET https://example.test/status", "curl -XHEAD https://example.test/status",
                "gh repo clone owner/repo", "gh pr checkout 42", "curl -e https://referrer.example https://example.test/status"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }

        // Approving a read is not approving a write to the same host: the
        // approval a command needs is the grant its own request yields.
        let readApproval = PermissionBroker.approvalGrants(
            for: .shell(command: "curl https://example.test/status", toolName: "Bash")
        )
        let afterRead = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: readApproval
        ))
        #expect(afterRead.disposition(toolName: "Bash", command: "curl -d x https://example.test/delete") == .ask)
        for write in [
            "curl -d x https://example.test/delete", "curl -XPOST https://example.test/delete",
            "curl -F file=@a.txt https://example.test/upload", "curl -K write.conf",
            "docker --context production create alpine", "npm --scope @foo publish"
        ] {
            let asked = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: wider))
                .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": write]))
            #expect(asked?.requiresApproval == true, "\(write)")
            #expect(asked?.permissionRequest == .shell(command: write, toolName: "Bash"), "asked about as written: \(write)")
            let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
                runtime: .claudeCode, policy: wider, approvalGrants: asked?.approvalGrants ?? []
            ))
            #expect(approved.disposition(toolName: "Bash", command: write) == .allowed, "\(write) approved once")
        }

        // A shell's -c string is judged as a command: a rule allowing the
        // shell does not cover what the string does outside this machine.
        let interpreter = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["bash:*", "sh:*", "zsh:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: interpreter))
            for command in [
                "bash -c 'curl -d x https://example.test/hook'", "sh -c \"git push origin main\"",
                "zsh -ec 'gh workflow run deploy.yml'", "bash -c \"bash -c 'gh pr create --fill'\"",
                "bash -c \"echo \\\"done\\\" && curl --json '{}' https://example.test/hook\"", "bash -c \"$PAYLOAD\""
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in ["bash -c 'make test'", "sh -c \"echo 'git push' > notes.txt\"", "bash scripts/build.sh"] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }
        let wrapped = "bash -c 'curl -d x https://example.test/hook'"
        let asked = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: interpreter))
            .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": wrapped]))
        #expect(asked?.requiresApproval == true)
        let wrappedApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: interpreter, approvalGrants: asked?.approvalGrants ?? []
        ))
        #expect(wrappedApproved.disposition(toolName: "Bash", command: wrapped) == .allowed,
                "approving the wrapped write does not ask again")

        // A substitution runs even inside double quotes; inside single quotes
        // it is text.
        let echoing = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["echo:*", "date:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: echoing))
            #expect(guardrail.disposition(toolName: "Bash", command: "echo \"`curl --json '{}' https://example.test/hook`\"") != .allowed,
                    "\(runtime.rawValue)")
            #expect(guardrail.disposition(toolName: "Bash", command: "echo '`curl -d x https://example.test/hook`'") == .allowed,
                    "\(runtime.rawValue)")
        }

        // A runner, a function, `eval`, a trap or an alias runs what this does
        // not read, so a broad Bash rule asks about it.
        let broadBash = AgentPolicy(level: .custom, allowedTools: ["Read", "Glob", "Grep", "Bash"], allowedShellPatterns: ["*"])
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: broadBash))
            for command in [
                "env -u CI git push origin main", "env -S 'git push origin main'", "nice -n 5 curl -d x https://example.test/hook",
                "timeout 30 gh workflow run deploy.yml", "printf 'origin main' | xargs git push",
                "xargs -r git push origin main </dev/null", "find . -maxdepth 0 -exec git push origin main ';'",
                "f(){ curl -d x https://example.test/hook; }; f", "eval 'git push origin main'",
                "x='git push origin main'; eval \"$x\"", "$CMD push origin main", "trap 'git push origin main' EXIT",
                "case x in x) git push origin main;; esac", "git -c alias.ship=push ship origin main", "git ship origin main",
                "git lfs push origin main", "rsync -a dist/ deploy@host:/srv/app", "yarn npm publish",
                "python3 -c 'print(1)'", "node --eval='require(\"child_process\").execSync(\"git push origin main\")'",
                "osascript -e 'tell application \"Mail\" to send'", "PATH=/tmp/evil:$PATH ls"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in [
                "env -u CI git status", "timeout 30 make test", "nice -n 5 swift build", "git add -A", "git blame README.md",
                "python3 scripts/report.py", "python3 -m pytest", "node build.js", "find . -name '*.swift' -exec wc -l {} +",
                "bash -c 'echo $HOME'"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }
        for written in ["git -c alias.ship=push ship origin main", "env -u CI git push origin main"] {
            let ask = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: broadBash))
                .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": written]))
            #expect(ask?.requiresApproval == true, "\(written)")
            let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
                runtime: .claudeCode, policy: broadBash, approvalGrants: ask?.approvalGrants ?? []
            ))
            #expect(approved.disposition(toolName: "Bash", command: written) == .allowed, "\(written) approved once")
        }

        // A skill that hands the provider DOCKER_HOST routes Docker where this
        // process cannot see, so a rule allowing docker still asks.
        var routed = Self.manifest(runtime: .claudeCode, policy: wider)
        routed.environmentKeyNames = ["DOCKER_HOST"]
        #expect(AgentRuntimePolicyGuard(manifest: routed).disposition(toolName: "Bash", command: "docker ps") == .ask)
        #expect(AgentRuntimePolicyGuard(manifest: routed).disposition(toolName: "Bash", command: "git status") == .allowed)

        // Approving a push is not approving a force: that needs its own yes.
        let plainPushAsk = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: wider))
            .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": "git push origin main"]))
        let plainPushApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: plainPushAsk?.approvalGrants ?? []
        ))
        #expect(plainPushApproved.disposition(toolName: "Bash", command: "git push origin main") == .allowed)
        #expect(plainPushApproved.disposition(toolName: "Bash", command: "git push origin main --force") == .ask)
        #expect(plainPushApproved.disposition(toolName: "Bash", command: "git push origin +main") == .ask)
        let forceAsk = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: wider))
            .violation(for: .toolUse(name: "Bash", id: "tool-2", input: ["command": "git push origin main --force"]))
        let forceApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: forceAsk?.approvalGrants ?? []
        ))
        #expect(forceApproved.disposition(toolName: "Bash", command: "git push origin main --force") == .allowed,
                "an approved force push is not asked about again")

        // The Docker workspace's shell tool runs the same command on another
        // transport, so the same gate applies, and approves it as a shell command.
        var workspace = Self.manifest(runtime: .claudeCode, policy: wider)
        workspace.providerRender.runtimeSupportTools += DockerWorkspaceMCPProjection.runtimeSupportToolDescriptors(
            runtimeProfile: AgentRuntimeCapabilityProfileService.profile(for: .claudeCode, executablePath: "")
        )
        let shellTool = DockerWorkspaceMCPProjection.providerToolPermission(for: DockerWorkspaceMCPProjection.toolName)
        if !workspace.providerRender.runtimeSupportTools.isEmpty {
            // (A command naming a URL is refused outright by the tool's schema.)
            let write = ParsedEvent.toolUse(name: shellTool, id: "tool-3", input: ["command": "git push origin main"])
            let asked = AgentRuntimePolicyGuard(manifest: workspace).violation(for: write)
            #expect(asked?.requiresApproval == true)
            #expect(AgentRuntimePolicyGuard(manifest: workspace).violation(for: .toolUse(
                name: shellTool, id: "tool-4", input: ["command": "git status"]
            )) == nil, "a command the shell rules allow runs")
            #expect(AgentRuntimePolicyGuard(manifest: workspace).violation(for: .toolUse(
                name: shellTool, id: "tool-5", input: ["command": "rm -rf build"]
            ))?.requiresApproval == true, "one they do not allow is asked about, as Bash's would be")
            var approved = workspace
            approved.approvalGrants = asked?.approvalGrants ?? []
            #expect(AgentRuntimePolicyGuard(manifest: approved).violation(for: write) == nil)
        }
        #expect(!workspace.providerRender.runtimeSupportTools.isEmpty, "Claude Code can carry the workspace shell")

        // Ask asks before every workspace command, as before every Bash
        // command; Auto asks before none.
        for (level, policy) in [(AgentPolicyLevel.review, AgentPolicy.preset(.review)), (.autonomous, .preset(.autonomous))] {
            var manifest = Self.manifest(runtime: .claudeCode, policy: policy)
            manifest.providerRender.runtimeSupportTools += DockerWorkspaceMCPProjection.runtimeSupportToolDescriptors(
                runtimeProfile: AgentRuntimeCapabilityProfileService.profile(for: .claudeCode, executablePath: "")
            )
            let violation = AgentRuntimePolicyGuard(manifest: manifest).violation(for: .toolUse(
                name: shellTool, id: "tool-6", input: ["command": "rm -rf build"]
            ))
            #expect((violation?.requiresApproval == true) == (level == .review), "\(level.rawValue)")
        }

        // A command that only mentions one in a quoted operand runs nothing
        // outside ASTRA and keeps the rule.
        let mentioning = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: policy))
        #expect(mentioning.disposition(toolName: "Bash", command: "git log --grep 'git push'") == .allowed)

        let request = PermissionRequest.shell(command: "git push origin main", toolName: "Bash")
        let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode,
            policy: policy,
            approvalGrants: PermissionBroker.approvalGrants(for: request)
        ))
        #expect(approved.disposition(toolName: "Bash", command: "git push origin main") == .allowed, "approved once, not asked twice")
    }

    /// `docker context use` points every later command at another daemon, so
    /// a plain `docker run` is local only when the daemon it reaches is.
    @Test("A docker command is local only when the daemon it reaches is")
    func dockerDaemonLocalityFollowsTheCLI() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-docker-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func context(_ name: String, host: String) throws {
            let meta = directory.appendingPathComponent("contexts/meta/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["Name": name, "Endpoints": ["docker": ["Host": host]]])
                .write(to: meta.appendingPathComponent("meta.json"))
        }
        func current(_ name: String) throws {
            try JSONSerialization.data(withJSONObject: ["currentContext": name])
                .write(to: directory.appendingPathComponent("config.json"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try context("desktop-linux", host: "unix:///Users/me/.docker/run/docker.sock")
        try context("production", host: "ssh://deploy@prod.example")
        func local(_ environment: [String: String] = [:], context explicit: String? = nil) -> Bool {
            DockerDaemonLocality.isLocal(context: explicit, environment: environment, configDirectory: directory)
        }

        #expect(local(), "no current context: the default local socket")
        try current("desktop-linux")
        #expect(local())
        try current("production")
        #expect(!local(), "the CLI's current context is a remote daemon")
        #expect(local(context: "desktop-linux"), "an explicit local context")
        #expect(!local(["DOCKER_CONTEXT": "production"]))
        #expect(!local(["DOCKER_HOST": "tcp://build.example:2376"]))
        #expect(local(["DOCKER_HOST": "unix:///var/run/docker.sock"]))
        #expect(!local(context: "unknown"), "a context that cannot be read is not called local")
    }

    /// Custom's own rules decide whether enabled local tools become grants:
    /// with Bash ask-first (the default Custom policy) no runtime turns them
    /// into `<exe> *` patterns, and with Bash allowed every runtime does.
    @Test("Custom grants local tools only when its rules allow Bash")
    func customGrantsLocalToolsOnlyWithBash() {
        let withoutBash = AgentPolicy(level: .custom, allowedTools: ["Read", "Glob", "Grep"], askFirstTools: ["Bash"])
        let withBash = AgentPolicy(level: .custom, allowedTools: ["Read", "Glob", "Grep", "Bash"])
        for runtime in [AgentRuntimeID.codexCLI, .cursorCLI, .antigravityCLI, .openCodeCLI] {
            let adapter = ProviderPolicyAdapterRegistry.adapter(for: runtime)
            func render(_ policy: AgentPolicy) -> ProviderPolicyRender {
                adapter.render(policy: policy, context: PolicyRenderContext(
                    runtimeID: runtime,
                    model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
                    workspacePath: "/tmp/astra-policy-matrix",
                    additionalPaths: [],
                    requestedAllowedTools: ["Read", "Grep"],
                    localToolCommands: ["gcloud"],
                    environmentKeyNames: [],
                    credentialLabels: [],
                    providerFeatures: adapter.supportedFeatures
                ))
            }
            #expect(!render(withoutBash).allowedShellPatterns.contains("gcloud *"), "\(runtime.rawValue) without Bash")
            #expect(render(withBash).allowedShellPatterns.contains("gcloud *"), "\(runtime.rawValue) with Bash")
        }

        // Copilot renders the grant as `--allow-tool shell(gcloud:*)`, both in
        // its adapter and when the launch recomposes its arguments.
        let copilot = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(
            copilotCLI: CopilotCLICapabilities(helpText: "--allow-tool\n--output-format")
        ))
        func copilotRender(_ policy: AgentPolicy) -> ProviderPolicyRender {
            copilot.render(policy: policy, context: PolicyRenderContext(
                runtimeID: .copilotCLI,
                model: AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI),
                workspacePath: "/tmp/astra-policy-matrix",
                additionalPaths: [],
                requestedAllowedTools: ["Read", "Grep"],
                localToolCommands: ["gcloud"],
                environmentKeyNames: [],
                credentialLabels: [],
                providerFeatures: copilot.supportedFeatures
            ))
        }
        #expect(!copilotRender(withoutBash).allowedTools.contains("shell(gcloud:*)"), "copilot without Bash")
        #expect(copilotRender(withBash).allowedTools.contains("shell(gcloud:*)"), "copilot with Bash")
        let adapters = (try? String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Astra/Services/Runtime/AgentPolicyAdapters.swift"),
            encoding: .utf8
        )) ?? ""
        #expect(adapters.contains(
            "localToolCommands: PolicyLocalToolGrants.policyScoped(context.localToolCommands, for: policy),"
        ), "the launch-time recomposition gets the policy-scoped commands")
    }

    /// A browser page change is a write to a site. It asks at Custom whether
    /// it arrives as `astra-browser click` or as the browser MCP tool, and one
    /// approval of the command covers both; reads and navigation keep the rule.
    @Test("Custom asks before a browser page change on either transport")
    func customAsksBeforeBrowserPageChanges() {
        let tool = BrowserBridgeMCPProjection.providerToolPermission
        let shell = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["astra-browser:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: shell))
            for command in [
                "astra-browser click --selector button.primary",
                "astra-browser fill --label Email --text a@example.test",
                "astra-browser batch '{\"actions\":[]}'"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in [
                "astra-browser read-page --format markdown", "astra-browser page --limit 2000",
                "astra-browser analyze", "astra-browser navigate https://example.test"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }

        let mcp = AgentPolicy(level: .custom, allowedTools: ["Read", "Glob", "Grep", "Bash", tool])
        let click = ParsedEvent.toolUse(name: tool, id: "tool-1", input: ["command": "click", "arguments": ["selector": "button"]])
        let read = ParsedEvent.toolUse(name: tool, id: "tool-2", input: ["command": "read-page"])
        let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: mcp))
        #expect(guardrail.violation(for: read) == nil)
        let asked = guardrail.violation(for: click)
        #expect(asked?.requiresApproval == true)
        #expect(asked?.permissionRequest == .shell(command: "astra-browser click --selector 'button'", toolName: tool),
                "the card shows what will be clicked")
        let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: mcp, approvalGrants: asked?.approvalGrants ?? []
        ))
        #expect(approved.violation(for: click) == nil, "approving the page change does not ask again")
        #expect(approved.disposition(toolName: "Bash", command: "astra-browser click --selector button") == .allowed,
                "one approval covers both transports")
        let otherClick = ParsedEvent.toolUse(name: tool, id: "tool-3", input: ["command": "click", "arguments": ["selector": "#delete"]])
        #expect(approved.violation(for: otherClick)?.requiresApproval == true, "a click on another control asks again")
        #expect(approved.disposition(toolName: "Bash", command: "astra-browser fill --label Email --text a") == .ask,
                "another page change needs its own approval")

        let auto = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: .preset(.autonomous)))
        #expect(auto.violation(for: click) == nil, "Auto asks nothing")
    }

    // MARK: - Helpers

    private static func manifest(
        runtime: AgentRuntimeID,
        policy: AgentPolicy,
        approvalGrants: [PermissionGrant] = []
    ) -> RunPermissionManifest {
        let adapter = ProviderPolicyAdapterRegistry.adapter(
            for: runtime,
            runtimeCapabilities: AgentRuntimePolicyCapabilities(copilotCLI: copilotCapabilities)
        )
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            requestedAllowedTools: ["Read", "Grep"],
            localToolCommands: [],
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )
        return RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "run",
            providerID: runtime,
            providerVersion: nil,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            policyLevel: policy.level,
            policyScope: .builtInDefault,
            providerRender: adapter.render(policy: policy, context: context),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: approvalGrants
        )
    }

    private static let copilotCapabilities = CopilotCLICapabilities(helpText: """
        --allow-all
        --allow-all-tools
        --allow-all-paths
        --allow-all-urls
        --available-tools
        --excluded-tools
        --output-format
        --stream
        --no-ask-user
        --secret-env-vars
        """)

    private static func manifest(
        runtime: AgentRuntimeID,
        level: AgentPolicyLevel,
        localToolCommands: [String] = []
    ) -> RunPermissionManifest {
        RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "run",
            providerID: runtime,
            providerVersion: nil,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            policyLevel: level,
            policyScope: .builtInDefault,
            providerRender: render(runtime: runtime, level: level, localToolCommands: localToolCommands),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: []
        )
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func render(
        runtime: AgentRuntimeID,
        level: AgentPolicyLevel,
        localToolCommands: [String] = []
    ) -> ProviderPolicyRender {
        let copilot = CopilotCLICapabilities(helpText: """
        --allow-all
        --allow-all-tools
        --allow-all-paths
        --allow-all-urls
        --available-tools
        --excluded-tools
        --output-format
        --stream
        --no-ask-user
        --secret-env-vars
        """)
        let adapter = ProviderPolicyAdapterRegistry.adapter(
            for: runtime,
            runtimeCapabilities: AgentRuntimePolicyCapabilities(copilotCLI: copilot)
        )
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            requestedAllowedTools: ["Read", "Grep"],
            localToolCommands: localToolCommands,
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )
        return adapter.render(policy: .preset(level), context: context)
    }
}
