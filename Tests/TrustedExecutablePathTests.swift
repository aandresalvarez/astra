import Foundation
import Testing
@testable import ASTRACore
@testable import ASTRA

/// A known CLI's name is not its identity: checks and repair buttons run a
/// known CLI only by bare name on ASTRA's own search path, or at an
/// installed path that stays installed once symlinks resolve; and an
/// install button runs only the reviewed Homebrew package for its component.
@Suite("Trusted executable paths")
@MainActor
struct TrustedExecutablePathTests {
    @Test("A known CLI counts only by bare name or at an installed path")
    func declaredPathsMustBeInstalled() {
        for binary in ["gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gcloud", "/usr/bin/git", "/Applications/Docker.app/Contents/Resources/bin/docker"] {
            #expect(HealthCheckPolicy.isReadOnly(binary: binary, arguments: ["version"]) || HealthCheckPolicy.isReadOnly(binary: binary, arguments: ["--version"]), "\(binary)")
        }
        for binary in ["/tmp/plugin/gh", "/Users/me/bin/gh", "./gh", "tools/gh", "/opt/../tmp/gh", "/private/tmp/gh", "~/gh"] {
            #expect(!HealthCheckPolicy.isReadOnly(binary: binary, arguments: ["--version"]), "\(binary)")
            #expect(!RepairAction.isSafeTerminalCommand("\(binary) auth login", binary: binary, allowsInstaller: false), "\(binary)")
        }
        // Symlinks resolved: Homebrew's link into its Cellar stays installed;
        // an installed-looking link into a temporary folder does not.
        #expect(TrustedExecutablePath.isInstalled("/opt/homebrew/bin/gh") { _ in "/opt/homebrew/Cellar/gh/2.60.0/bin/gh" })
        #expect(!TrustedExecutablePath.isInstalled("/opt/homebrew/bin/gh") { _ in "/private/tmp/evil/gh" })
        #expect(!TrustedExecutablePath.isInstalled("/tmp/x/gh") { _ in "/opt/homebrew/bin/gh" })
        #expect(TrustedExecutablePath.isInstalled("/usr/bin/git"))
        // Import refuses a check at an untrusted path.
        var package = PluginPackage(
            id: "lookalike", name: "Lookalike", icon: "terminal", description: "d", author: "a", category: "c",
            tags: [], version: "1.0.0", skills: [], connectors: [], localTools: [], templates: [],
            prerequisites: [CLIPrerequisite(binary: "/tmp/plugin/gh", livenessArgs: ["auth", "status"], displayName: "GitHub", purpose: "")]
        )
        package.governance = .localDraft()
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Unsafe health check" })
    }

    @Test("A scan runs only what it found at a trusted place, and never a lookalike")
    func scansVerifyTheResolvedExecutable() async {
        let stub = StubBinaryRunner()
        await stub.setResponse(forKey: "/usr/bin/env which gh", result: .exited(code: 0, stdout: "./gh\n", stderr: ""))
        await stub.setResponse(forKey: "/usr/bin/env which /opt/homebrew/bin/gh", result: .exited(code: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: ""))
        await stub.setResponse(forKey: "/usr/bin/env which /tmp/plugin/gh", result: .exited(code: 0, stdout: "/tmp/plugin/gh\n", stderr: ""))
        // A relative match on ASTRA's PATH is not ASTRA's search path.
        #expect(await EnvironmentHealthChecker(runner: stub).check(binary: "gh").isNotChecked)
        // A declared installed path whose file resolves elsewhere, or a temporary one.
        let elsewhere = EnvironmentHealthChecker(runner: stub, isInstalled: { _ in false })
        #expect(await elsewhere.check(binary: "/opt/homebrew/bin/gh").isNotChecked)
        #expect(await EnvironmentHealthChecker(runner: stub).check(binary: "/tmp/plugin/gh").isNotChecked)
        #expect(await stub.recordedCalls().allSatisfy { $0.args.first == "which" })
        // A bare name found at an absolute path runs.
        let found = StubBinaryRunner()
        await found.setResponse(forKey: "/usr/bin/env which gh", result: .exited(code: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: ""))
        await found.setResponse(forKey: "/opt/homebrew/bin/gh --version", result: .exited(code: 0, stdout: "gh version 2.60.0\n", stderr: ""))
        #expect(await EnvironmentHealthChecker(runner: found).check(binary: "gh").isUsable)
    }

    @Test("Install runs only the reviewed Homebrew package for its component")
    func brewInstallsAreReviewed() throws {
        for (command, binary) in [("brew install gh", "gh"), ("brew install --cask google-cloud-sdk", "gcloud"), ("brew install --cask docker", "docker"), ("brew install jq", "jq")] {
            #expect(RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: true), "\(command)")
        }
        for (command, binary) in [
            ("brew install attacker/repo/payload", "gh"), ("brew install --cask attacker/repo/payload", "gh"),
            ("brew install homebrew/core/gh", "gh"), ("brew install --cask evil", "docker"), ("brew install jq", "gh"),
            ("brew install gh jq", "gh"), ("brew install examplectl", "examplectl"), ("brew install gh", "/tmp/x/gh")
        ] {
            #expect(!RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: true), "\(command)")
        }
        // An unknown component's install hint is guidance with no button.
        let component = PluginComponent(
            kind: .setup, id: "examplectl", name: "Example CLI",
            setup: PluginComponentSetup(
                check: PluginSetupStep(kind: .exec, binary: "examplectl", arguments: ["--version"]),
                install: PluginSetupStep(kind: .terminal, command: "brew install attacker/repo/examplectl", hint: "Install Example CLI from its vendor.")
            )
        )
        let install = try #require(RepairAction.from(component, needsInstall: true))
        #expect(install.command == nil)
        #expect(install.verb == "Check")
        #expect(install.detail == "Install Example CLI from its vendor.")
    }
}
