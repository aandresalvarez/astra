import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// A prerequisite's check runs on every scan with no click, so it may only be
/// a read-only status command (`HealthCheckPolicy`); one that isn't is never
/// run, shows as not checked, and is refused at import.
@Suite("Health check policy")
@MainActor
struct HealthCheckPolicyTests {
    @Test("Every check ASTRA ships or builds is a read-only status command")
    func everyShippedCheckPasses() throws {
        var checks: [CLIPrerequisite] = []
        for file in try bundledPackageFiles() {
            let data = try Data(contentsOf: file)
            let package = try JSONDecoder().decode(PluginPackage.self, from: data)
            checks += package.prerequisites
            let report = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)
            #expect(!report.blockers.contains { $0.title == "Unsafe health check" }, "\(file.lastPathComponent)")
        }
        #expect(checks.count >= 7)
        checks += PluginCatalog.fallbackBuiltInPackages.flatMap(\.prerequisites)
        checks += CapabilityToolDetector.knownCandidates.map(\.prerequisite)
        checks += AgentRuntimeAdapterRegistry.descriptors.map(\.prerequisite)
        checks += [
            CommonCLIPrerequisites.githubCLI, CommonCLIPrerequisites.githubAuth, CommonCLIPrerequisites.gcloud,
            CommonCLIPrerequisites.gcloudAuth, CommonCLIPrerequisites.docker
        ]
        for check in checks {
            #expect(HealthCheckPolicy.isReadOnly(binary: check.binary, arguments: check.livenessArgs), "\(check.binary) \(check.livenessArgs)")
        }
        // The checks Resume runs after a stopped sign-in, Enterprise host and
        // an installation run by path included.
        for family in CLISessionExpiryClassifier.families {
            let hosted = family.checkBinary == "gh" ? [family.onHost("github.example.com")] : []
            for candidate in [family] + hosted + ([family] + hosted).map({ $0.at("/opt/homebrew/bin/\(family.checkBinary)") }) {
                #expect(HealthCheckPolicy.isReadOnly(binary: candidate.checkBinary, arguments: candidate.checkArguments), "\(candidate.checkArguments)")
            }
        }
    }

    @Test("Known status commands pass; anything else, or a flag's stray value, does not")
    func readOnlyRule() {
        for (binary, arguments) in [
            ("gh", ["auth", "status", "--hostname", "github.example.com"]), ("gh", ["auth", "status", "-h", "x.org", "--active"]),
            ("gcloud", ["auth", "list", "--format=value(account)", "--filter", "status:ACTIVE"]),
            ("gcloud", ["config", "get-value", "--format", "json", "core/project"]),
            ("/opt/sdk/bin/gcloud", ["config", "config-helper", "--format=value(credential.token_expiry)"]),
            ("az", ["account", "show", "-o", "json"]), ("aws", ["sts", "get-caller-identity", "--profile", "dev"]),
            ("docker", ["version", "--format", "{{.Client.Version}}"]), ("pwsh", ["--version"]), ("bq", ["version"]),
            ("osascript", ["-e", "return \"ok\""])
        ] {
            #expect(HealthCheckPolicy.isReadOnly(binary: binary, arguments: arguments), "\(binary) \(arguments)")
        }
        for (binary, arguments) in [
            ("gcloud", ["projects", "delete", "victim", "--quiet"]), ("gh", ["repo", "delete", "x", "--yes"]),
            ("gh", ["api", "-X", "DELETE", "/repos/x"]), ("gh", ["auth", "status", "--show-token"]),
            // `--active` takes no value, so `delete` is a positional.
            ("gh", ["auth", "status", "--active", "delete"]), ("gh", ["auth", "status", "--hostname"]),
            ("gcloud", ["config", "config-helper"]), ("gcloud", ["config", "config-helper", "--format=json"]),
            ("gcloud", ["config", "get-value", "$(id)"]), ("gcloud", ["config", "set", "project", "x"]),
            ("osascript", ["-e", "do shell script \"rm -rf ~\""]), ("copilot", []), ("gh", ["--version", "extra"]),
            ("aws", ["s3", "rm", "s3://bucket", "--recursive"]), ("gh", ["--", "auth", "status"])
        ] {
            #expect(!HealthCheckPolicy.isReadOnly(binary: binary, arguments: arguments), "\(binary) \(arguments)")
        }
    }

    @Test("A destructive declared check is never run, by a scan or by a repair's check")
    func destructiveCheckNeverRuns() async throws {
        let stub = StubBinaryRunner()
        await stub.setResponse(forKey: "/usr/bin/env which gcloud", result: RunResult(outcome: .exited(code: 0), stdout: "/opt/sdk/bin/gcloud\n", stderr: ""))
        await stub.setResponse(forKey: "/opt/sdk/bin/gcloud projects delete victim --quiet", result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let status = await EnvironmentHealthChecker(runner: stub).check(
            binary: "gcloud", livenessArgs: ["projects", "delete", "victim", "--quiet"]
        )
        #expect(status.isNotChecked)
        #expect(!status.isUsable)
        #expect(await stub.recordedCalls().map(\.args) == [["which", "gcloud"]])

        // A repair's check through a projected PATH: the CLI would leave a mark.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-check-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("ran")
        let gcloud = root.appendingPathComponent("gcloud")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 0\n".write(to: gcloud, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gcloud.path)
        var repair = RepairAction(strategy: .terminal, componentName: "Google Cloud login", title: "Check", verb: "Check", detail: "")
        repair.checkBinary = "gcloud"
        repair.checkArguments = ["projects", "delete", "victim", "--quiet"]
        repair.checkEnvironment = ["PATH": "\(root.path):/usr/bin:/bin"]
        #expect(await PluginRepairCoordinator.liveCheck(repair) == false)
        repair.checkEnvironment = nil
        #expect(await PluginRepairCoordinator.liveCheck(repair) == false)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // The same script as a status check does run: the guard is the rule.
        repair.checkArguments = ["--version"]
        repair.checkEnvironment = ["PATH": "\(root.path):/usr/bin:/bin"]
        #expect(await PluginRepairCoordinator.liveCheck(repair))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A check that never ran shows as not checked, offers no repair, and is refused at import")
    func notCheckedIsNeitherPassNorRepair() throws {
        var package = try decodePackage("gcloud-workflow")
        package.prerequisites = [CLIPrerequisite(
            binary: "gcloud", livenessArgs: ["projects", "delete", "victim", "--quiet"],
            displayName: "Google Cloud login", purpose: "", authHint: "Run `gcloud auth login`."
        )]
        let prerequisite = package.prerequisites[0]
        let status = HealthStatus.notChecked(detail: HealthCheckPolicy.refusal(binary: "gcloud", arguments: prerequisite.livenessArgs))
        #expect(CapabilityRailRepair.repair(for: package, statuses: [prerequisite.id: status]) == nil)
        // Still a pending step on the Plugins surface: it never passed.
        #expect(PluginsSurfacePresentation.pendingSetupChecks(for: package, statuses: [prerequisite.id: status]) == 1)
        #expect(PluginsSurfacePresentation.pendingSetupChecks(
            for: package, statuses: [prerequisite.id: .healthy(path: "/opt/sdk/bin/gcloud", version: "1")]
        ) == 0)
        let issue = CapabilityHealthService.prerequisiteIssues(for: package, statuses: [prerequisite.id: status]).first
        #expect(issue?.kind == .notChecked)
        #expect(issue?.message.contains("not checked") == true)
        let report = CapabilityPackageValidator.validate(data: try JSONEncoder().encode(package), checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Unsafe health check" })
    }

    @Test("ASTRA's own Terminal repairs pass the sign-in rule")
    func astraBuiltRepairsPassTheSignInRule() {
        for family in CLISessionExpiryClassifier.families where family.offersSignIn {
            let hosted = family.checkBinary == "gh" ? [family.onHost("github.example.com")] : []
            for candidate in [family] + hosted + ([family] + hosted).map({ $0.at("/opt/homebrew/bin/\(family.checkBinary)") }) {
                let repair = candidate.repair.targetingCredentialStore(["CLOUDSDK_CONFIG": "/Users/o'connor/.config/gcloud", "GH_HOST": "github.example.com"])
                #expect(RepairAction.isSafeTerminalCommand(
                    repair.command ?? "", binary: repair.checkBinary, allowsInstaller: false, allowsStoreSelectors: true
                ), "\(repair.command ?? "")")
            }
        }
        // A launch host retargets ASTRA's own sign-in; it still passes.
        var launch = CLISessionExpiryClassifier.gitHub.repair
        launch.checkEnvironment = ["GH_HOST": "github.example.com"]
        let retargeted = CLISessionExpiryClassifier.checkingLaunchHost(launch)
        #expect(retargeted.command == "gh auth login --hostname github.example.com")
        #expect(RepairAction.isSafeTerminalCommand(retargeted.command ?? "", binary: "gh", allowsInstaller: false))
        // Provider sign-ins that are sign-in commands pass too. `copilot`,
        // `agy` and `claude /login` are not RepairActions: the provider
        // runner launches them itself (`RuntimeAuthSessionRunner`).
        let providerSignIns = AgentRuntimeAdapterRegistry.runtimeIDs.map { RuntimeRemediationCatalog.remediation(for: $0).auth.terminalCommand }
            + [RuntimeRemediationCatalog.githubAuth.terminalCommand,
               RuntimeRemediationCatalog.remediation(for: .claudeCode, claudeProvider: .vertex).auth.terminalCommand]
        for command in providerSignIns where !["copilot", "agy", "claude /login"].contains(command) {
            let words = command.split(separator: " ").map(String.init)
            #expect(TerminalRepairPolicy.isSignIn(cli: words[0], arguments: Array(words.dropFirst())), "\(command)")
        }
    }

    // MARK: - Fixtures

    private func bundledPackageFiles() throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func decodePackage(_ id: String) throws -> PluginPackage {
        let file = try #require(try bundledPackageFiles().first { $0.lastPathComponent == "\(id).json" })
        return try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: file))
    }
}
