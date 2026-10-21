import Foundation
import Testing
import os
import ASTRACore
@testable import ASTRA

@MainActor
@Suite("Plugin repair destination admission")
struct PluginRepairDestinationTests {
    @Test("Source sign-in cannot select an untrusted GitHub host or overwrite ADC", arguments: [
        "gh auth login --hostname attacker.example --web", "gh auth refresh -h github.example.com",
        "gcloud auth login --update-adc"
    ])
    func sourceCannotSelectSensitiveDestination(command: String) throws {
        let binary = String(command.prefix { $0 != " " })
        #expect(!RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: false))
        let component = PluginComponent(kind: .setup, id: "login", name: "Provider login", setup: .init(
            check: .init(kind: .exec, binary: binary, arguments: ["--version"]),
            repair: .init(kind: .terminal, command: command, hint: "Sign in to this provider.")
        ))
        let repair = try #require(RepairAction.from(component))
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        let terminal = TerminalSpy()
        RepairActionRunner.run(RepairAction(strategy: .terminal, componentName: "Saved repair", title: "Sign in",
            verb: "Sign in", detail: "", command: command, checkBinary: binary), terminal: terminal,
            copy: { _ in Issue.record("An unsafe saved command cannot be copied as a fallback") })
        #expect(terminal.launched.isEmpty)
    }

    @Test("A run-selected credential directory becomes manual setup without changing its read-only check", arguments: [
        "CLOUDSDK_CONFIG", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"
    ])
    func selectedDirectoryCannotReceiveLogin(key: String) {
        let environment = [key: "/tmp/workspace/credentials"]
        let original = key == "CLOUDSDK_CONFIG" ? CLISessionExpiryClassifier.googleCloud.repair : CLISessionExpiryClassifier.gitHub.repair
        let repair = original.checking(in: environment).targetingCredentialStore(environment)
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        #expect(repair.checkBinary == original.checkBinary)
        #expect(repair.checkArguments == original.checkArguments)
        #expect(repair.checkEnvironment == environment)
    }

    @Test("Stored selector-prefixed commands cannot bypass destination admission")
    func legacyPrefixCannotLaunchOrCopy() {
        let terminal = TerminalSpy()
        let repair = RepairAction(strategy: .terminal, componentName: "Saved repair", title: "Sign in", verb: "Sign in",
            detail: "", command: "env CLOUDSDK_CONFIG='/tmp/workspace/credentials' gcloud auth login", checkBinary: "gcloud")
        RepairActionRunner.run(repair, terminal: terminal,
            copy: { _ in Issue.record("The old unsafe selector prefix cannot reach the clipboard") })
        #expect(terminal.launched.isEmpty)
    }

    @Test("The classifier offers manual setup for an untrusted GitHub host")
    func hostCannotProduceAnAutomaticSignIn() throws {
        let repair = CLISessionExpiryClassifier.gitHub.onHost("github.example.com").repair
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        #expect(repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"])
        let stop = try #require(CLISessionExpiryClassifier.stop(
            content: "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            command: "GH_HOST=github.example.com gh api user"))
        #expect(stop.repairContext?.offersAction == false)
        #expect(stop.repairContext?.repair.command == nil)
        #expect(stop.repairContext?.repair.checkArguments?.last == "github.example.com")
    }

    @Test("An indeterminate GitHub host is verified after manual setup")
    func unknownHostDoesNotGuessASignInDestination() throws {
        let repair = CLISessionExpiryClassifier.gitHub.onEveryHost().repair
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        #expect(repair.checkArguments == ["auth", "status", "--active"])
        let stop = try #require(CLISessionExpiryClassifier.stop(
            content: "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            command: "gh pr list --repo team/app"))
        #expect(stop.repairContext?.repair.command == nil)
        #expect(stop.repairContext?.offersAction == false)
    }

    @Test("Default provider sign-ins remain executable")
    func defaultProviderSignInsRemainAvailable() {
        for (binary, command) in [("gh", "gh auth login --hostname github.com --web"),
                                  ("gcloud", "gcloud auth login --no-launch-browser")] {
            #expect(RepairAction.isSafeTerminalCommand(command, binary: binary, allowsInstaller: false))
        }
    }

    @Test("An unrelated provider's selectors do not disable a default sign-in")
    func selectorChecksStayScopedToTheirCLI() {
        let github = CLISessionExpiryClassifier.gitHub.repair
        #expect(github.targetingCredentialStore(["CLOUDSDK_CONFIG": "/tmp/cloud"]) == github)
        let cloud = CLISessionExpiryClassifier.googleCloud.repair
        #expect(cloud.targetingCredentialStore(["GH_CONFIG_DIR": "/tmp/gh", "GH_HOST": "github.example.com"]) == cloud)
        let install = RepairAction(strategy: .terminal, componentName: "GitHub CLI", title: "Install", verb: "Install",
            detail: "", command: "brew install gh", checkBinary: "gh")
        #expect(install.targetingCredentialStore(["GH_CONFIG_DIR": "/tmp/gh"]).command == "brew install gh")
    }

    @Test("Default GitHub repair pins github.com independently of Terminal's environment")
    func defaultGitHubHostIsExplicitAtExecution() {
        let terminal = TerminalSpy()
        RepairActionRunner.run(CLISessionExpiryClassifier.gitHub.repair, terminal: terminal)
        #expect(terminal.launched == ["gh auth login --hostname github.com"])
    }

    @Test("An Enterprise verification cannot offer a default-host automatic login")
    func repairAndVerificationMustNameTheSameTrustedHost() throws {
        let component = PluginComponent(kind: .setup, id: "enterprise", name: "Enterprise", setup: .init(
            check: .init(kind: .exec, binary: "gh", arguments: ["auth", "status", "--hostname", "github.example.com"]),
            repair: .init(kind: .terminal, command: "gh auth login", hint: "Sign in.")
        ))
        let repair = try #require(RepairAction.from(component))
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        #expect(repair.checkArguments?.last == "github.example.com")
    }

    @Test("Source repair hints remain bounded plain guidance")
    func untrustedHintIsBoundedAndDoesNotHideControls() throws {
        let hint = "\u{202E}Manual setup\u{0000}\n" + String(repeating: "x", count: 10_000)
        let component = PluginComponent(kind: .setup, id: "login", name: "Provider login", setup: .init(
            check: .init(kind: .exec, binary: "gh", arguments: ["--version"]),
            repair: .init(kind: .terminal, command: "gh auth login --hostname attacker.example", hint: hint)
        ))
        let repair = try #require(RepairAction.from(component))
        #expect(repair.command == nil)
        #expect(repair.detail.count <= 600)
        #expect(!repair.detail.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
        #expect(repair.detail.hasPrefix("Manual setup "))
    }

    private final class TerminalSpy: TerminalCommandLaunching {
        private let commands = OSAllocatedUnfairLock(initialState: [String]())
        var launched: [String] { commands.withLock { $0 } }
        func launchInTerminal(command: String) throws { commands.withLock { $0.append(command) } }
        func openTerminalApp() { commands.withLock { $0.append("opened Terminal") } }
    }
}
