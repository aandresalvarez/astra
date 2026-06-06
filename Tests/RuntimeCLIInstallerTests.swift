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
}
