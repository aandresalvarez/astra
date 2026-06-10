import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("RuntimeCLIInstaller")
struct RuntimeCLIInstallerTests {
    @Test("Claude install uses npm")
    func claudeInstallUsesNPM() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/npm install -g @anthropic-ai/claude-code",
            result: RunResult(outcome: .exited(code: 0), stdout: "installed\n", stderr: "")
        )

        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { binary in binary == "npm" ? "/opt/homebrew/bin/npm" : "" }
        )

        let plan = installer.plan(for: .claudeCode)
        #expect(plan?.displayCommand == "npm install -g @anthropic-ai/claude-code")

        let result = await installer.install(runtime: .claudeCode)
        #expect(result.succeeded)
        #expect(result.plan?.installerName == "npm")

        let calls = await runner.recordedCalls()
        #expect(calls == [
            StubBinaryRunner.Call(path: "/opt/homebrew/bin/npm", args: ["install", "-g", "@anthropic-ai/claude-code"])
        ])
    }

    @Test("Copilot install prefers Homebrew before npm")
    func copilotInstallPrefersHomebrew() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/brew install copilot-cli",
            result: RunResult(outcome: .exited(code: 0), stdout: "installed\n", stderr: "")
        )

        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { binary in
                switch binary {
                case "brew": "/opt/homebrew/bin/brew"
                case "npm": "/opt/homebrew/bin/npm"
                default: ""
                }
            }
        )

        let plan = installer.plan(for: .copilotCLI)
        #expect(plan?.displayCommand == "brew install copilot-cli")

        let result = await installer.install(runtime: .copilotCLI)
        #expect(result.succeeded)
        #expect(result.plan?.installerName == "Homebrew")

        let calls = await runner.recordedCalls()
        #expect(calls == [
            StubBinaryRunner.Call(path: "/opt/homebrew/bin/brew", args: ["install", "copilot-cli"])
        ])
    }

    @Test("Missing package manager returns actionable fallback")
    func missingPackageManagerReturnsFallback() async {
        let runner = StubBinaryRunner()
        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { _ in "" }
        )

        let result = await installer.install(runtime: .copilotCLI)
        #expect(!result.succeeded)
        #expect(result.plan == nil)
        #expect(result.summary.contains("No supported installer"))
        #expect(result.detail?.contains("Homebrew") == true)
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("Antigravity installer uses guidance instead of piping remote shell")
    func antigravityInstallerUsesGuidanceInsteadOfRemoteShell() async {
        let runner = StubBinaryRunner()
        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { binary in binary == "bash" ? "/bin/bash" : "" }
        )

        #expect(installer.plan(for: .antigravityCLI) == nil)

        let result = await installer.install(runtime: .antigravityCLI)
        #expect(!result.succeeded)
        #expect(result.plan == nil)
        #expect(result.detail?.contains("official Google Antigravity CLI setup docs") == true)
        #expect(result.detail?.contains("| bash") == false)
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("Cursor installer uses official guidance")
    func cursorInstallerUsesOfficialGuidance() async {
        let runner = StubBinaryRunner()
        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { _ in "" }
        )

        #expect(installer.plan(for: .cursorCLI) == nil)

        let result = await installer.install(runtime: .cursorCLI)
        #expect(!result.succeeded)
        #expect(result.plan == nil)
        #expect(result.detail?.contains("Install Cursor CLI") == true)
        #expect(result.detail?.contains("cursor-agent login") == true)
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("OpenCode install prefers Homebrew before npm")
    func openCodeInstallPrefersHomebrew() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/brew install opencode",
            result: RunResult(outcome: .exited(code: 0), stdout: "installed\n", stderr: "")
        )

        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { binary in
                switch binary {
                case "brew": "/opt/homebrew/bin/brew"
                case "npm": "/opt/homebrew/bin/npm"
                default: ""
                }
            }
        )

        #expect(installer.plan(for: .openCodeCLI)?.displayCommand == "brew install opencode")

        let result = await installer.install(runtime: .openCodeCLI)
        #expect(result.succeeded)
        #expect(result.plan?.installerName == "Homebrew")
    }

    @Test("OpenCode install falls back to npm when Homebrew is absent")
    func openCodeInstallFallsBackToNPM() {
        let installer = RuntimeCLIInstaller(
            runner: StubBinaryRunner(),
            detectExecutable: { binary in binary == "npm" ? "/usr/local/bin/npm" : "" }
        )
        let plan = installer.plan(for: .openCodeCLI)
        #expect(plan?.displayCommand == "npm install -g opencode-ai")
        #expect(plan?.installerName == "npm")
    }

    @Test("Codex installs via npm")
    func codexInstallsViaNPM() {
        let installer = RuntimeCLIInstaller(
            runner: StubBinaryRunner(),
            detectExecutable: { binary in binary == "npm" ? "/opt/homebrew/bin/npm" : "" }
        )
        let plan = installer.plan(for: .codexCLI)
        #expect(plan?.displayCommand == "npm install -g @openai/codex")
        #expect(plan?.executablePath == "/opt/homebrew/bin/npm")
    }

    @Test("Install failures keep a multi-line log tail for the output disclosure")
    func installFailureKeepsLogTail() async {
        let runner = StubBinaryRunner()
        let longStderr = (1...80).map { "npm ERR! line \($0)" }.joined(separator: "\n")
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/npm install -g @anthropic-ai/claude-code",
            result: RunResult(outcome: .exited(code: 1), stdout: "", stderr: longStderr)
        )
        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { binary in binary == "npm" ? "/opt/homebrew/bin/npm" : "" }
        )

        let result = await installer.install(runtime: .claudeCode)

        #expect(!result.succeeded)
        let log = result.fullLog ?? ""
        #expect(log.contains("\n"), "log tail must preserve newlines")
        #expect(log.hasSuffix("npm ERR! line 80"))
        #expect(log.count <= 2_000)
    }

    @Test("npm EACCES failures get a targeted permission hint")
    func eaccesFailureGetsPermissionHint() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/npm install -g @anthropic-ai/claude-code",
            result: RunResult(
                outcome: .exited(code: 243),
                stdout: "",
                stderr: "npm ERR! Error: EACCES: permission denied, mkdir '/usr/local/lib/node_modules'"
            )
        )
        let installer = RuntimeCLIInstaller(
            runner: runner,
            detectExecutable: { binary in binary == "npm" ? "/opt/homebrew/bin/npm" : "" }
        )

        let result = await installer.install(runtime: .claudeCode)

        #expect(!result.succeeded)
        #expect(result.detail?.contains("denied write access") == true)
        #expect(result.detail?.contains("npm's global prefix") == true)

        let npmPlan = RuntimeCLIInstallPlan(
            runtime: .claudeCode,
            installerName: "npm",
            executablePath: "/opt/homebrew/bin/npm",
            arguments: ["install", "-g", "x"],
            displayCommand: "npm install -g x"
        )
        let brewPlan = RuntimeCLIInstallPlan(
            runtime: .copilotCLI,
            installerName: "Homebrew",
            executablePath: "/opt/homebrew/bin/brew",
            arguments: ["install", "x"],
            displayCommand: "brew install x"
        )
        #expect(RuntimeCLIInstaller.permissionFailureHint(in: "all good", plan: npmPlan) == nil)
        #expect(RuntimeCLIInstaller.permissionFailureHint(
            in: "Error: Permission denied @ rb_sysopen",
            plan: brewPlan
        )?.contains("brew doctor") == true)
        #expect(RuntimeCLIInstaller.permissionFailureHint(
            in: "EACCES: permission denied",
            plan: brewPlan
        )?.contains("npm") == false, "Homebrew failures must not surface npm-specific guidance")
    }
}
