import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// Stands in for Terminal. `onLaunch` plays the part of the user finishing
/// the browser sign-in, which is what makes gcloud rewrite the ADC file.
private final class RecordingLauncher: TerminalCommandLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    let onLaunch: @Sendable () -> Void

    init(onLaunch: @escaping @Sendable () -> Void = {}) {
        self.onLaunch = onLaunch
    }

    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }

    func launchInTerminal(command: String) throws {
        lock.lock(); _commands.append(command); lock.unlock()
        onLaunch()
    }

    func openTerminalApp() {}
}

private final class DeniedLauncher: TerminalCommandLaunching, @unchecked Sendable {
    func launchInTerminal(command _: String) throws {
        throw TerminalLaunchError(reason: "Not authorized")
    }
    func openTerminalApp() {}
}

private actor PhaseLog {
    private(set) var phases: [AntigravityADCSetupPhase] = []
    func append(_ phase: AntigravityADCSetupPhase) { phases.append(phase) }
}

private struct ADCHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adc-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".config/gcloud"),
            withIntermediateDirectories: true
        )
    }

    var credentialsURL: URL {
        root.appendingPathComponent(".config/gcloud/application_default_credentials.json")
    }

    func writeCredentials(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: credentialsURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeService(
    home: ADCHome,
    launcher: RecordingLauncher = RecordingLauncher(),
    runner: StubBinaryRunner = StubBinaryRunner(),
    gcloud: String = "/opt/gcloud"
) -> AntigravityADCSetupService {
    AntigravityADCSetupService(
        homeDirectory: home.root.path,
        launcher: launcher,
        runner: runner,
        detectExecutable: { $0 == "gcloud" ? gcloud : "" },
        maxDuration: 9,
        pollInterval: 3,
        commandTimeout: 5,
        sleep: { _ in }
    )
}

@Suite("Antigravity ADC setup")
struct AntigravityADCSetupServiceTests {
    @Test("Status reads only the quota project out of the ADC file")
    func statusReadsQuotaProject() throws {
        let home = try ADCHome()
        defer { home.remove() }
        let service = makeService(home: home)

        #expect(service.status() == .notSignedIn)

        home.writeCredentials(["type": "authorized_user", "refresh_token": "secret", "quota_project_id": "my-project"])
        #expect(service.status() == .signedIn(quotaProject: "my-project"))

        home.writeCredentials(["type": "authorized_user", "refresh_token": "secret"])
        #expect(service.status() == .signedIn(quotaProject: nil))

        #expect(makeService(home: home, gcloud: "").status() == .gcloudMissing)
    }

    @Test("Login command shell-quotes the gcloud path and project")
    func loginCommandIsQuoted() {
        #expect(
            AntigravityADCSetupService.loginCommand(gcloudPath: "/Users/a b/gcloud", project: "my-project")
                == "'/Users/a b/gcloud' auth application-default login --project='my-project'"
        )
    }

    @Test("Setup signs in through Terminal, then sets the quota project itself")
    func setupSignsInThenSetsQuotaProject() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let launcher = RecordingLauncher {
            home.writeCredentials(["type": "authorized_user", "refresh_token": "secret"])
        }
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default set-quota-project my-project",
            result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: "Credentials saved")
        )
        let service = makeService(home: home, launcher: launcher, runner: runner)

        let outcome = await service.setUp(project: " my-project ") { _ in }

        #expect(outcome == .configured(quotaProject: "my-project"))
        #expect(launcher.commands == ["'/opt/gcloud' auth application-default login --project='my-project'"])
        #expect(await runner.recordedCalls() == [
            StubBinaryRunner.Call(path: "/opt/gcloud", args: ["auth", "application-default", "set-quota-project", "my-project"])
        ])
    }

    @Test("Setup times out without touching the quota project when sign-in never finishes")
    func setupTimesOutWithoutSignIn() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let runner = StubBinaryRunner()
        let service = makeService(home: home, runner: runner)

        let outcome = await service.setUp(project: "my-project") { _ in }

        #expect(outcome == .timedOut)
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("An invalid project never reaches Terminal")
    func invalidProjectIsRejectedUpFront() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let launcher = RecordingLauncher()
        let service = makeService(home: home, launcher: launcher)

        let outcome = await service.setUp(project: "My Project") { _ in }

        guard case .invalidProject = outcome else {
            Issue.record("Expected invalidProject, got \(outcome)")
            return
        }
        #expect(launcher.commands.isEmpty)
        #expect(await service.setUp(project: "") { _ in } != .timedOut)
    }

    @Test("A project permission error surfaces gcloud's own message")
    func quotaProjectFailureSurfacesDetail() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default set-quota-project other-project",
            result: RunResult(
                outcome: .exited(code: 1),
                stdout: "",
                stderr: "ERROR: Cannot add the project \"other-project\" to ADC as the quota project because the account does not have the \"serviceusage.services.use\" permission on this project."
            )
        )
        let service = makeService(home: home, runner: runner)

        let outcome = await service.setQuotaProject("other-project")

        guard case .quotaProjectFailed(let detail) = outcome else {
            Issue.record("Expected quotaProjectFailed, got \(outcome)")
            return
        }
        #expect(detail.contains("serviceusage.services.use"))
    }

    @Test("The copy/paste fallback carries the resolved, quoted gcloud path")
    func fallbackCommandUsesResolvedGcloudPath() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let service = AntigravityADCSetupService(
            homeDirectory: home.root.path,
            launcher: DeniedLauncher(),
            runner: StubBinaryRunner(),
            detectExecutable: { $0 == "gcloud" ? "/Users/a b/google-cloud-sdk/bin/gcloud" : "" },
            maxDuration: 3,
            pollInterval: 3,
            sleep: { _ in }
        )
        let log = PhaseLog()

        _ = await service.setUp(project: "my-project") { await log.append($0) }

        let expected = "'/Users/a b/google-cloud-sdk/bin/gcloud' auth application-default login --project='my-project'"
        let phases = await log.phases
        #expect(phases.contains(.launched(.manualCopy(reason: "Not authorized"), command: expected)))
    }

    @Test("A gcloud timeout or launch failure is not reported as a project permission error")
    func nonExitFailuresAreClassifiedSeparately() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let key = "/opt/gcloud auth application-default set-quota-project my-project"

        for result in [
            RunResult(outcome: .timedOut, stdout: "", stderr: ""),
            RunResult(outcome: .launchFailed("no such file"), stdout: "", stderr: "")
        ] {
            let runner = StubBinaryRunner()
            await runner.setResponse(forKey: key, result: result)
            let outcome = await makeService(home: home, runner: runner).setQuotaProject("my-project")
            guard case .gcloudUnavailable(let detail) = outcome else {
                Issue.record("Expected gcloudUnavailable, got \(outcome)")
                continue
            }
            #expect(!detail.contains("administrator"))
        }
    }

    @Test("Cancelling during set-quota-project stays a silent cancel")
    func cancelledQuotaProjectIsSilent() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/gcloud auth application-default set-quota-project my-project",
            result: RunResult(outcome: .cancelled, stdout: "", stderr: "")
        )

        let outcome = await makeService(home: home, runner: runner).setQuotaProject("my-project")

        #expect(outcome == .cancelled)
        #expect(outcome.message == nil)
    }

    @Test("A cancelled setup never runs set-quota-project, even if sign-in completes")
    func cancelledSetupLeavesGcloudConfigAlone() async throws {
        let home = try ADCHome()
        defer { home.remove() }
        let runner = StubBinaryRunner()
        let launcher = RecordingLauncher {
            home.writeCredentials(["type": "authorized_user", "refresh_token": "secret"])
        }
        let service = makeService(home: home, launcher: launcher, runner: runner)

        let task = Task { await service.setUp(project: "my-project") { _ in } }
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .cancelled)
        #expect(await runner.recordedCalls().isEmpty)
    }
}
