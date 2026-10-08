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
    // ASTRA follow Ask: a rule that allows Bash or `git:*` must not let
    // `git push` through unasked on any runtime.
    @Test("Custom rules that allow Bash or git still ask before a push")
    func customAsksBeforeExternalCommandsItsRulesAllow() {
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
        // Not only Git: anything the shared risk classifier calls a write
        // outside this machine asks, while local writes and reads keep the rule.
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
                "curl -X POST https://hooks.example.test/build -d ok",
                "curl --json '{\"build\":1}' https://hooks.example.test/api",
                "gcloud run deploy api --source .",
                "gh workflow run deploy.yml",
                "gh secret set TOKEN",
                "gh run cancel 12345",
                "npm unpublish widget@1.0.0",
                "npm deprecate widget@1.0.0 obsolete",
                "npm dist-tag add widget@1.0.0 beta",
                "npm token revoke abc123",
                "npm token create",
                "curl -XPOST https://hooks.example.test/build",
                "curl -sSd ok https://hooks.example.test/build",
                "curl -dsecret https://hooks.example.test/build",
                "aws s3 cp report.csv s3://bucket/report.csv",
                "aws ec2 terminate-instances --instance-ids i-1",
                "kubectl set image deployment/app app=image:v2",
                "kubectl label pod api-1 tier=web",
                "aws s3api put-object --bucket b --key get-secret --body file.txt",
                "kubectl apply -f deploy.yaml --dry-run=none",
                "docker --config /tmp/astra-docker-cfg --context production create alpine",
                "docker -l debug -H ssh://deploy@host create alpine",
                "gh deploy",
                "psql -c 'DELETE FROM widgets'",
                "psql -c 'SELECT 1' -c 'DROP TABLE widgets'",
                "psql -f migrate.sql",
                "mysql -e 'UPDATE widgets SET a = 1'",
                "npm --registry https://registry.example publish",
                "git submodule foreach 'git push origin main'",
                "git rebase -x 'git push origin HEAD' main",
                "git bisect run curl -d x https://example.test/hook",
                "wget --method=POST --body-data=x https://hooks.example.test/build",
                "wget --body-file=report.json https://hooks.example.test/build",
                "wget --method=DELETE https://hooks.example.test/item/1",
                "npm star widget",
                "npm adduser --auth-type=legacy",
                "npm add-user",
                "npm unstar widget",
                "gh api repos/o/r/issues/1/comments -fbody=hello",
                "git send-pack git@github.com:owner/repo.git refs/heads/main",
                "docker --context production run alpine",
                "docker -H ssh://deploy@host rm web",
                "docker -H unix:///var/run/docker.sock buildx build --push -t registry.example/app .",
                "docker -H unix:///var/run/docker.sock build --output type=registry -t registry.example/app .",
                "docker -H unix:///var/run/docker.sock compose push",
                "docker -H unix:///var/run/docker.sock image push registry.example/app",
                "docker --context production create alpine",
                "docker -H ssh://deploy@host volume create data",
                "curl -K write.conf",
                "curl --config=write.conf https://example.test/x",
                "wget -e post_data=x https://example.test/x"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in [
                "curl https://example.test/status", "gcloud compute instances list", "git commit -m wip",
                "gh workflow list", "gh run view 12345", "npm dist-tag ls widget", "npm token list", "npm install",
                "curl -sSL https://example.test/status", "curl -sSLo status.json https://example.test/status",
                "aws s3 cp s3://bucket/report.csv report.csv", "aws s3 cp report.csv s3://bucket/report.csv --dryrun",
                "aws sts get-caller-identity", "kubectl get pods", "kubectl apply -f app.yaml --dry-run=client",
                "kubectl --kubeconfig /tmp/test get pods", "kubectl --context prod -n web describe pod api-1",
                "kubectl apply -f deploy.yaml --dry-run=server", "npm install publish",
                "gh status", "psql -c 'SELECT * FROM widgets'", "mysql -e 'SHOW TABLES'",
                "psql --command='EXPLAIN SELECT 1'",
                "git submodule foreach 'git status'", "git submodule update --init",
                "wget https://example.test/status", "wget --method=GET https://example.test/status",
                "git send-pack --dry-run git@github.com:owner/repo.git refs/heads/main",
                "curl -X GET https://example.test/status", "curl --request=GET https://example.test/status",
                "curl -XHEAD https://example.test/status",
                "gh repo clone owner/repo", "gh pr checkout 42",
                "docker -H unix:///var/run/docker.sock run alpine",
                "docker -H unix:///var/run/docker.sock build -t app .",
                "docker -H unix:///var/run/docker.sock create alpine",
                "docker -H ssh://deploy@host ps",
                "curl -e https://referrer.example https://example.test/status"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }

        // The classifier knows push plumbing on its own, not only through the
        // observer's reading.
        #expect(ShellCommandRiskClassifier.actsOutsideMachine(forShellSegment: "git send-pack git@github.com:o/r.git main"))
        #expect(!ShellCommandRiskClassifier.actsOutsideMachine(forShellSegment: "git send-pack --dry-run git@github.com:o/r.git main"))

        // Approving a read is not approving a write to the same host: the
        // host-scoped read grant must not stand in for asking.
        let readApproval = PermissionBroker.approvalGrants(
            for: .shell(command: "curl https://example.test/status", toolName: "Bash")
        )
        let afterRead = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: readApproval
        ))
        #expect(afterRead.disposition(toolName: "Bash", command: "curl -d x https://example.test/delete") == .ask)
        let writeApproval = PermissionBroker.approvalGrants(
            for: .shell(command: "curl -d x https://example.test/delete", toolName: "Bash")
        )
        let afterWrite = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: writeApproval
        ))
        #expect(afterWrite.disposition(toolName: "Bash", command: "curl -d x https://example.test/delete") == .allowed,
                "an approved write is not asked about again")
        for write in ["curl -XPOST https://example.test/delete", "curl -F file=@a.txt https://example.test/upload",
                      "curl -K write.conf"] {
            let asked = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: wider))
                .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": write]))
            #expect(asked?.requiresApproval == true, "\(write)")
            let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
                runtime: .claudeCode, policy: wider, approvalGrants: asked?.approvalGrants ?? []
            ))
            #expect(approved.disposition(toolName: "Bash", command: write) == .allowed, "\(write) approved once")
        }

        // A shell run with -c runs its payload: a rule allowing the shell
        // does not cover what the payload does outside this machine.
        let interpreter = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["bash:*", "sh:*", "zsh:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: interpreter))
            for command in [
                "bash -c 'curl -d x https://example.test/hook'",
                "sh -c \"git push origin main\"",
                "zsh -ec 'gh workflow run deploy.yml'",
                "bash -c \"bash -c 'gh pr create --fill'\"",
                "bash -c \"echo \\\"done\\\" && curl --json '{}' https://example.test/hook\""
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in ["bash -c 'make test'", "sh -c \"echo 'git push' > notes.txt\"", "bash scripts/build.sh"] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) != .ask, "\(runtime.rawValue) \(command)")
            }
        }
        let wrapped = "bash -c 'curl -d x https://example.test/hook'"
        let asked = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: interpreter))
            .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": wrapped]))
        #expect(asked?.requiresApproval == true)
        #expect(
            asked?.permissionRequest == .shell(command: "curl -d x https://example.test/hook", toolName: "Bash"),
            "the payload is what is asked about"
        )
        let payloadApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: interpreter, approvalGrants: asked?.approvalGrants ?? []
        ))
        #expect(payloadApproved.disposition(toolName: "Bash", command: wrapped) == .allowed,
                "approving the wrapped write does not ask again")

        // A backtick substitution runs even inside double quotes; inside
        // single quotes it is text. (`$(…)` is denied outright.)
        let echoing = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["echo:*", "date:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: echoing))
            for command in [
                "echo \"`curl --json '{}' https://example.test/hook`\"",
                "echo \"result: `gh secret set TOKEN`\""
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in ["echo \"today is `date`\"", "echo '`curl -d x https://example.test/hook`'"] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }
        let substituted = "echo \"`curl --json '{}' https://example.test/hook`\""
        let substitutionAsk = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: echoing))
            .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": substituted]))
        #expect(substitutionAsk?.permissionRequest == .shell(command: "curl --json '{}' https://example.test/hook", toolName: "Bash"))
        let substitutionApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: echoing, approvalGrants: substitutionAsk?.approvalGrants ?? []
        ))
        #expect(substitutionApproved.disposition(toolName: "Bash", command: substituted) == .allowed)

        // A runner with options still runs its command: `env -u CI` and
        // `nice -n 5` must not hide a push or a write.
        let broadBash = AgentPolicy(level: .custom, allowedTools: ["Read", "Glob", "Grep", "Bash"], allowedShellPatterns: ["*"])
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: broadBash))
            for command in [
                "env -u CI git push origin main",
                "env -i PATH=/usr/bin git push origin main",
                "env -S 'git push origin main'",
                "nice -n 5 curl -d x https://example.test/hook",
                "timeout 30 gh workflow run deploy.yml",
                "time -p git push origin main",
                "env -u CI nice -n 5 git push origin main",
                "printf 'origin main' | xargs git push",
                "find . -maxdepth 0 -exec git push origin main ';'",
                "find . -name x -execdir curl -d x https://example.test/hook \\;",
                "f(){ curl -d x https://example.test/hook; }; f",
                "function g { git push origin main; }; g",
                "h() ( gh workflow run deploy.yml ); h",
                "eval 'git push origin main'",
                "watch -n 5 git push origin main",
                "trap 'git push origin main' EXIT",
                "case x in x) git push origin main;; esac",
                "case $1 in a|b) curl -d x https://example.test/hook;; esac",
                "yarn npm publish",
                "rsync -a dist/ deploy@host:/srv/app",
                "scp build.tar deploy@host:/tmp",
                "eval git push origin main",
                "timeout 30 timeout 30 timeout 30 timeout 30 timeout 30 curl -d x https://example.test/hook",
                "git -c alias.ship=push ship origin main",
                "git -c 'alias.ship=push --force' ship origin main",
                "git ship origin main",
                "git lfs push origin main",
                "python3 -c 'import urllib.request;urllib.request.urlopen(\"https://example.test\", data=b\"x\")'",
                "node -e \"fetch('https://example.test', {method: 'POST'})\"",
                "osascript -e 'tell application \"Mail\" to send'",
                "timeout 30 python3 -c 'print(1)'",
                "git branch --format=x | xargs -n 1 git push origin --delete"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in [
                "env -u CI git status", "timeout 30 make test", "nice -n 5 swift build",
                "timeout 30 timeout 30 timeout 30 timeout 30 make test", "git add -A", "git blame README.md",
                "git -c alias.st=status st",
                "python3 scripts/report.py", "python3 -m pytest", "node build.js",
                "find . -name '*.swift' -exec wc -l {} +",
                "f(){ echo hi; }; f",
                "trap 'rm -f /tmp/lock' EXIT",
                "case x in x) echo hi;; esac",
                "rsync -a src/ backup/"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }
        for written in [
            "f(){ curl -d x https://example.test/hook; }; f",
            "git -c alias.ship=push ship origin main",
            "git ship origin main",
            "timeout 30 timeout 30 timeout 30 timeout 30 timeout 30 curl -d x https://example.test/hook"
        ] {
            let ask = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: broadBash))
                .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": written]))
            #expect(ask?.requiresApproval == true, "\(written)")
            let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
                runtime: .claudeCode, policy: broadBash, approvalGrants: ask?.approvalGrants ?? []
            ))
            #expect(approved.disposition(toolName: "Bash", command: written) == .allowed, "\(written) approved once")
        }
        let wrappedPush = "env -u CI git push origin main"
        let pushAsk = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: broadBash))
            .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": wrappedPush]))
        #expect(pushAsk?.permissionRequest == .shell(command: "git push origin main", toolName: "Bash"))
        let pushApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: broadBash, approvalGrants: pushAsk?.approvalGrants ?? []
        ))
        #expect(pushApproved.disposition(toolName: "Bash", command: wrappedPush) == .allowed)

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
        #expect(asked?.permissionRequest == .shell(command: "astra-browser click", toolName: tool))
        let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: mcp, approvalGrants: asked?.approvalGrants ?? []
        ))
        #expect(approved.violation(for: click) == nil, "approving the page change does not ask again")
        #expect(approved.disposition(toolName: "Bash", command: "astra-browser click --selector button") == .allowed)

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
