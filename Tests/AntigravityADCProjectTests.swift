import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// 2026-10-14: two bare `gcloud auth application-default login` runs from a
/// terminal rewrote the ADC file without `quota_project_id`. ASTRA kept no
/// copy of the project, so Antigravity lost its billing project and the
/// Settings field came back empty after a restart. These pin ASTRA's own
/// record of the project and its path into every `agy` invocation.
@Suite("Antigravity ADC billing project")
struct AntigravityADCProjectTests {
    private static let quotaKey = AntigravityCLIRuntime.quotaProjectEnvironmentKey

    private func adcDefaults(project: String? = nil) -> InMemoryDefaults {
        let defaults = InMemoryDefaults()
        defaults.set(AntigravityAuthMode.adc.rawValue, forKey: AppStorageKeys.antigravityAuthMode)
        if let project {
            defaults.set(project, forKey: AppStorageKeys.antigravityADCProject)
        }
        return defaults
    }

    private func launchEnvironment(_ defaults: UserDefaults) -> [String: String] {
        AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 30,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted),
            defaults: defaults
        ).environment
    }

    // MARK: Store

    @Test("The store keeps only well-formed project IDs and re-keys composers on a change")
    func storeValidatesAndBumpsRevision() {
        let defaults = InMemoryDefaults()
        #expect(AntigravityADCProjectStore.load(defaults: defaults) == "")

        #expect(!AntigravityADCProjectStore.save("Not A Project", defaults: defaults))
        #expect(defaults.object(forKey: AppStorageKeys.antigravityADCProject) == nil)
        #expect(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) == 0)

        #expect(AntigravityADCProjectStore.save(" my-project \n", defaults: defaults))
        #expect(AntigravityADCProjectStore.load(defaults: defaults) == "my-project")
        #expect(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) == 1)

        // Saving the same project again is not a settings change.
        #expect(AntigravityADCProjectStore.save("my-project", defaults: defaults))
        #expect(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) == 1)

        // A value corrupted outside the store never comes back out of it.
        defaults.set("a b c", forKey: AppStorageKeys.antigravityADCProject)
        #expect(AntigravityADCProjectStore.load(defaults: defaults) == "")
    }

    // MARK: Launch and probe environment

    @Test("ADC launches bill ASTRA's saved project through GOOGLE_CLOUD_QUOTA_PROJECT")
    func adcLaunchCarriesSavedProject() {
        let environment = launchEnvironment(adcDefaults(project: "my-project"))
        #expect(environment["AGY_ADC_AUTH"] == "true")
        #expect(environment[Self.quotaKey] == "my-project")
    }

    @Test("Without a saved project an ADC launch leaves billing to the gcloud file")
    func adcLaunchWithoutProjectExportsNothingExtra() {
        #expect(AntigravityCLIRuntime.authEnvironment(defaults: adcDefaults()) == ["AGY_ADC_AUTH": "true"])
        #expect(AntigravityCLIRuntime.authEnvironment(defaults: adcDefaults(project: "Bad Project")) == ["AGY_ADC_AUTH": "true"])
    }

    @Test("Consumer sign-in never sets a quota project, even with one saved")
    func consumerLaunchIgnoresSavedProject() {
        let defaults = adcDefaults(project: "my-project")
        defaults.set(AntigravityAuthMode.consumer.rawValue, forKey: AppStorageKeys.antigravityAuthMode)

        #expect(AntigravityCLIRuntime.authEnvironment(defaults: defaults).isEmpty)
        #expect(AntigravityCLIRuntime.authEnvironment(mode: .consumer, adcProject: "my-project").isEmpty)
    }

    @Test("The live readiness check runs agy with the same billing project as a launch")
    func liveReadinessCheckCarriesProject() async throws {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/agy --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.2\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/agy --print Reply with ASTRA_READY only. --print-timeout 25s --sandbox",
            result: RunResult(outcome: .exited(code: 0), stdout: "ASTRA_READY\n", stderr: "")
        )
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { $0 == "agy" ? "/opt/agy" : "" },
            isExecutable: { !$0.isEmpty }
        )
        let configuration = RuntimeReadinessConfiguration(
            runtime: .antigravityCLI,
            claudePath: "",
            copilotPath: "",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: "",
            antigravityAuthMode: .adc,
            antigravityADCProject: "my-project"
        )

        let report = await service.check(configuration: configuration)

        #expect(report.state == .ready)
        let calls = await runner.recordedCalls()
        let environments = await runner.recordedEnvironments()
        let liveIndex = try #require(calls.firstIndex { $0.args.first == "--print" })
        let liveEnvironment = try #require(environments[liveIndex])
        #expect(liveEnvironment["AGY_ADC_AUTH"] == "true")
        #expect(liveEnvironment[Self.quotaKey] == "my-project")
    }

    @Test("Provider snapshots carry the saved project and re-key when it changes")
    func providerSnapshotCarriesProject() {
        let defaults = adcDefaults(project: "first-project")
        let first = RuntimeSettingsSnapshotStore.providerSnapshot(defaults: defaults)
        #expect(first.antigravityADCProject == "first-project")
        #expect(first.readinessConfiguration(for: .antigravityCLI).antigravityADCProject == "first-project")

        defaults.set("second-project", forKey: AppStorageKeys.antigravityADCProject)
        let second = RuntimeSettingsSnapshotStore.providerSnapshot(defaults: defaults)
        #expect(second.antigravityADCProject == "second-project")
        #expect(first.signature != second.signature)
    }

    // MARK: Settings model

    @MainActor
    @Test("Settings saves the project only once gcloud accepted it")
    func settingsSavesProjectAfterGcloudAccepts() async throws {
        let home = try ProjectTestADCHome()
        defer { home.remove() }
        home.writeCredentials(["type": "authorized_user", "refresh_token": "secret"])
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default set-quota-project good-project",
            result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: "Credentials saved")
        )
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default set-quota-project denied-project",
            result: RunResult(outcome: .exited(code: 1), stdout: "", stderr: "PERMISSION_DENIED")
        )
        let defaults = adcDefaults()
        let model = AntigravityADCSetupModel(
            service: home.service(runner: runner),
            defaults: defaults,
            copyToPasteboard: { _ in }
        )
        model.refreshStatus()
        try await waitUntil { model.credentialStatus != nil }
        #expect(model.statusSummary == .noProject)

        model.project = "denied-project"
        #expect(model.needsOnlyQuotaProject)
        model.applyQuotaProject()
        try await waitUntil { model.result != nil }
        #expect(model.savedProject == "")
        #expect(AntigravityADCProjectStore.load(defaults: defaults) == "")

        model.project = "good-project"
        model.applyQuotaProject()
        try await waitUntil { model.result?.isSuccess == true }
        #expect(model.savedProject == "good-project")
        #expect(AntigravityADCProjectStore.load(defaults: defaults) == "good-project")
        #expect(!model.needsOnlyQuotaProject)
    }

    /// The incident itself: gcloud's file lost its quota project, ASTRA
    /// restarted, and the field and the billing project were both gone.
    @MainActor
    @Test("A restart after gcloud dropped the quota project still shows and bills the saved project")
    func savedProjectSurvivesGcloudRewriteAndRestart() async throws {
        let home = try ProjectTestADCHome()
        defer { home.remove() }
        home.writeCredentials(["type": "authorized_user", "refresh_token": "secret"])
        let defaults = adcDefaults(project: "good-project")

        let model = AntigravityADCSetupModel(
            service: home.service(runner: StubBinaryRunner()),
            defaults: defaults,
            copyToPasteboard: { _ in }
        )
        #expect(model.project == "good-project")
        model.refreshStatus()
        try await waitUntil { model.credentialStatus != nil }

        #expect(model.credentialStatus == .signedIn(quotaProject: nil))
        #expect(model.statusSummary == .billing(project: "good-project"))
        #expect(!model.needsOnlyQuotaProject)
        #expect(launchEnvironment(defaults)[Self.quotaKey] == "good-project")
    }

    @MainActor
    @Test("With nothing saved, Settings offers gcloud's project for adoption without saving it")
    func unsavedGcloudProjectIsOfferedNotSaved() async throws {
        let home = try ProjectTestADCHome()
        defer { home.remove() }
        home.writeCredentials(["type": "authorized_user", "refresh_token": "secret", "quota_project_id": "file-project"])
        let defaults = adcDefaults()

        let model = AntigravityADCSetupModel(
            service: home.service(runner: StubBinaryRunner()),
            defaults: defaults,
            copyToPasteboard: { _ in }
        )
        model.refreshStatus()
        try await waitUntil { model.credentialStatus != nil }

        #expect(model.project == "file-project")
        #expect(model.statusSummary == .unsavedGcloudProject("file-project"))
        #expect(model.needsOnlyQuotaProject)
        #expect(AntigravityADCProjectStore.load(defaults: defaults) == "")
    }
}

/// Bounded by poll count, not wall-clock time: the suite runs in parallel
/// and per-test timing budgets are unreliable under that load.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("condition never became true")
}

private struct ProjectTestADCHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adc-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".config/gcloud"),
            withIntermediateDirectories: true
        )
    }

    func writeCredentials(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: root.appendingPathComponent(".config/gcloud/application_default_credentials.json"))
    }

    func service(runner: StubBinaryRunner) -> AntigravityADCSetupService {
        AntigravityADCSetupService(
            homeDirectory: root.path,
            runner: runner,
            detectExecutable: { $0 == "gcloud" ? "/opt/gcloud" : "" },
            commandTimeout: 5,
            sleep: { _ in }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
