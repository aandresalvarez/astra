import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Slow-start prerequisite contract")
struct CLIPrerequisiteSlowStartTests {
    @Test("Different timeout policies never share cached admission", arguments: [false, true])
    func cacheIdentity(slowFirst: Bool) async {
        let runner = await stub(outcome: .timedOut)
        var strict = CommonCLIPrerequisites.gcloud
        strict.slowStartTimeout = nil
        let slow = CommonCLIPrerequisites.gcloud
        #expect(strict.id != slow.id)
        var longer = slow
        longer.slowStartTimeout = 30
        #expect(longer.id != slow.id)
        let cache = PreflightCache(checker: EnvironmentHealthChecker(runner: runner))
        var statuses: [String: HealthStatus] = [:]
        for prerequisite in slowFirst ? [slow, strict] : [strict, slow] {
            statuses[prerequisite.id] = await cache.status(for: prerequisite)
        }
        #expect(statuses[slow.id]?.isUsable == true)
        #expect(statuses[strict.id]?.isUsable == false)
        #expect(await runner.recordedCalls().count == 4)
    }

    @Test("Unsafe declared timeouts are refused before launching a process",
          arguments: [-1.0, 0.0, 1.0, 60.1, 1e20, Double.infinity, Double.nan])
    func invalidBudget(value: Double) async {
        let runner = await stub(outcome: .exited(code: 0))
        var prerequisite = CommonCLIPrerequisites.gcloud
        prerequisite.slowStartTimeout = value
        let status = await EnvironmentHealthChecker(runner: runner).check(prerequisite)
        #expect(status.isNotChecked)
        #expect(!status.isUsable)
        #expect(await runner.recordedCalls().isEmpty)
        let report = CapabilityPackageValidator.validate(package: package(prerequisites: [prerequisite]), checkPrerequisites: false)
        #expect(!report.canInstall)
    }

    @Test("Slow-start policy survives manifest JSON and component status lookup")
    func manifestRoundTrip() throws {
        let prerequisite = CommonCLIPrerequisites.gcloud
        let manifest = PluginManifestConverter.manifest(from: package(prerequisites: [prerequisite]))
        let restored = try PluginManifestConverter.decodePackage(from: JSONEncoder().encode(manifest))
        #expect(restored.prerequisites == [prerequisite])
        let component = try #require(manifest.components.first { $0.kind == .setup })
        #expect(PluginManifestConverter.prerequisiteID(of: component) == prerequisite.id)
    }

    @Test("A slow base probe cannot bypass a contextual access requirement")
    func contextualAccessStaysRequired() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/usr/bin/env which gh", result: .exited(code: 0, stdout: "/usr/local/bin/gh\n", stderr: ""))
        await runner.setResponse(forKey: "/usr/local/bin/gh auth status --hostname github.com", result: .init(outcome: .timedOut, stdout: "", stderr: ""))
        var prerequisite = CommonCLIPrerequisites.githubAuth
        prerequisite.slowStartTimeout = 20
        let cache = PreflightCache(checker: EnvironmentHealthChecker(runner: runner), contextualProbe: { _, _, _ in
            .authorizationRequired(detail: "Organization authorization required", authorizationURL: nil)
        })
        let status = await cache.status(for: prerequisite, workingDirectory: "/tmp/synthetic-repository")
        #expect(!status.isUsable)
        if case .unauthenticated = status { Issue.record("A timeout does not prove the account is signed out") }
    }

    @Test("Actual credential failures retain sign-in guidance without classifying network failures as signed out",
          arguments: [
            ("ERROR: You do not currently have an active account selected.", true),
            ("There was a problem refreshing your current auth tokens: invalid_grant: Token expired or revoked.", true),
            ("Reauthentication is needed. Please run gcloud auth login.", true),
            ("Reauthentication failed. cannot prompt during non-interactive execution.", true),
            ("There was a problem refreshing your current auth tokens: connection timed out", false),
            ("Connection refused", false)
          ])
    func credentialFailures(diagnostic: String, needsLogin: Bool) async {
        let runner = StubBinaryRunner()
        let prerequisite = CommonCLIPrerequisites.gcloudAuth
        await runner.setResponse(forKey: "/usr/bin/env which gcloud", result: .exited(code: 0, stdout: "/opt/homebrew/bin/gcloud\n", stderr: ""))
        await runner.setResponse(forKey: "/opt/homebrew/bin/gcloud " + prerequisite.livenessArgs.joined(separator: " "),
                                 result: .exited(code: 1, stdout: "", stderr: diagnostic))
        let status = await PreflightCache(checker: EnvironmentHealthChecker(runner: runner)).status(for: prerequisite)
        #expect(!status.isUsable)
        if needsLogin {
            guard case .unauthenticated(let detail) = status else {
                Issue.record("Expected an explicit credential failure, got \(status)")
                return
            }
            #expect(!detail.contains("invalid_grant"), "Expose canonical guidance, not raw credential diagnostics")
        } else {
            guard case .unresponsive = status else { Issue.record("Transport errors do not prove a sign-out"); return }
        }
    }

    @Test("Valid slow-start boundaries remain usable", arguments: [3.0, 60.0])
    func validBudget(value: Double) async {
        var prerequisite = CommonCLIPrerequisites.gcloud
        prerequisite.slowStartTimeout = value
        let runner = await stub(outcome: .exited(code: 0))
        #expect(await EnvironmentHealthChecker(runner: runner).check(prerequisite).isUsable)
        #expect(CapabilityPackageValidator.validate(package: package(prerequisites: [prerequisite]), checkPrerequisites: false).canInstall)
    }

    @Test("Repair checks preserve the longer budget but never accept silence")
    func repairNeedsProof() async throws {
        let runner = await stub(outcome: .timedOut)
        let repair = RepairAction(strategy: .terminal, componentName: "GCloud", title: "Check", verb: "Check", detail: "",
                                  checkBinary: "gcloud", checkArguments: ["--version"], checkTimeout: 20)
        let restored = try JSONDecoder().decode(RepairAction.self, from: JSONEncoder().encode(repair))
        #expect(restored.checkTimeout == 20)
        #expect(await PluginRepairCoordinator.liveCheck(restored, runner: runner) == false)
        #expect(await runner.recordedTimeouts().last == 20)
        var invalid = restored
        invalid.checkTimeout = .infinity
        let untouched = StubBinaryRunner()
        #expect(await PluginRepairCoordinator.liveCheck(invalid, runner: untouched) == false)
        #expect(await untouched.recordedCalls().isEmpty)
    }

    @Test("Session-expiry repairs keep the same slow-start budget, including ADC")
    func sessionExpiryRepairBudget() {
        #expect(CLISessionExpiryClassifier.googleCloud.repair.checkTimeout == 20)
        #expect(CLISessionExpiryClassifier.googleCloudApplicationDefault.repair.checkTimeout == 20)
        #expect(CLISessionExpiryClassifier.googleCloud.at("/opt/homebrew/bin/gcloud").repair.checkTimeout == 20)
        #expect(CLISessionExpiryClassifier.googleCloud.withOwnCredentials(["CLOUDSDK_AUTH_ACCESS_TOKEN"]).repair.checkTimeout == nil)
    }

    @Test("A transport failure offers a check, while an explicit credential failure offers sign-in")
    func repairMatchesEvidence() throws {
        let prerequisite = CommonCLIPrerequisites.gcloudAuth
        let package = package(prerequisites: [prerequisite])
        let component = try #require(PluginManifestConverter.setupComponents(of: package).first?.component)
        let status = HealthStatus.unresponsive(detail: "Connection timed out during credential refresh")
        let repair = try #require(RepairAction.from(component, status: status))
        #expect(repair.verb == "Check")
        #expect(repair.command == nil)
        #expect(repair.checkTimeout == 20)
        #expect(repair.detail.contains("Connection timed out"))
        #expect(CapabilityRailRepair.repair(for: package, statuses: [prerequisite.id: status]) == repair)
        let signIn = RepairAction.from(component, status: .unauthenticated(detail: "No active account"))
        #expect(signIn?.verb == "Sign in")
        #expect(signIn?.command == "gcloud auth login")
    }

    @Test("Unverified labels do not imply a repository or an invalid login")
    func unverifiedLabel() {
        let label = CapabilityPrerequisitePresentation.label(CommonCLIPrerequisites.gcloudAuth,
            status: .unverified(path: "/opt/homebrew/bin/gcloud", detail: "No answer"))
        #expect(label == "Not verified")
    }

    private func stub(outcome: RunResult.Outcome) async -> StubBinaryRunner {
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "/usr/bin/env which gcloud", result: .exited(code: 0, stdout: "/opt/homebrew/bin/gcloud\n", stderr: ""))
        await runner.setResponse(forKey: "/opt/homebrew/bin/gcloud --version", result: .init(outcome: outcome, stdout: "Google Cloud SDK\n", stderr: ""))
        return runner
    }

    private func package(prerequisites: [CLIPrerequisite]) -> PluginPackage {
        PluginPackage(id: "slow-start-qa", name: "Slow start QA", icon: "cloud", description: "Synthetic prerequisite contract",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0", skills: [], connectors: [], localTools: [],
            templates: [], prerequisites: prerequisites, governance: .builtInApproved())
    }
}
