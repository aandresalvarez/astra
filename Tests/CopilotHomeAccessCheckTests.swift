import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Every test builds a throwaway folder that stands in for `~/.copilot`; the
/// real one is never inspected. Root can read a mode-000 file, so the suite
/// only means something when it runs as a normal user.
@Suite("CopilotHomeAccessCheck", .enabled(if: getuid() != 0))
struct CopilotHomeAccessCheckTests {
    @Test("A healthy or missing Copilot home reports nothing")
    func healthyAndMissingHomesAreClean() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.makeDirectory("session-state", mode: 0o755)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)
        #expect(report.isClean)
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report) == nil)

        let missing = CopilotHomeAccessCheck.inspect(home: home.path + "-missing")
        #expect(missing.isClean)
    }

    @Test("A root-owned unreadable config.json blocks Copilot and names the chown fix")
    func foreignUnreadableConfigBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)

        // Another uid stands in for root: the file is unreadable either way,
        // and only its owner decides whether the fix is chown or chmod.
        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1)
        #expect(problem.path == config)
        #expect(problem.access == .unreadable)
        #expect(!problem.ownedByCurrentUser)
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("Copilot cannot read"))
        #expect(report.cause.contains("config.json"))
        #expect(report.cause.contains("mode 0"))
        #expect(report.cause.contains("sudo"))
        #expect(report.fixCommand == "sudo chown \"$USER\":staff '\(config)' && chmod u+rw '\(config)'")
        #expect(report.userMessage.contains("Run `\(report.fixCommand)` in Terminal"))
    }

    @Test("An unreadable file the user owns gets a chmod fix, not a chown")
    func ownUnreadableConfigGetsChmod() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.blocksCopilot)
        #expect(report.fixCommand == "chmod u+rw '\(config)'")
        #expect(!report.cause.contains("sudo"))
    }

    @Test("A read-only state folder warns instead of blocking, and a foreign one is chowned recursively")
    func unwritableDirectoryWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        let sessions = try home.makeDirectory("session-state", mode: 0o555)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        let problem = try #require(report.problems.first)
        #expect(problem.path == sessions)
        #expect(problem.isDirectory)
        #expect(problem.access == .unwritable)
        #expect(!report.blocksCopilot)
        #expect(report.cause.contains("Copilot cannot write"))
        #expect(report.fixCommand == "sudo chown -R \"$USER\":staff '\(sessions)' && chmod u+rwx '\(sessions)'")
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .warning)
    }

    @Test("An unusable home is reported once, not once per child")
    func unreadableHomeIsReportedAlone() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.setMode(0o000, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        #expect(report.problems.map(\.path) == [home.path])
        #expect(report.blocksCopilot)
        #expect(report.fixCommand == "sudo chown -R \"$USER\":staff '\(home.path)' && chmod u+rwx '\(home.path)'")
    }

    @Test("Read-only Copilot config files are a hardened setup, not a problem")
    func readOnlyConfigFilesAreClean() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o400)
        try home.write("mcp-config.json", mode: 0o444)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
        // Write access is waived, read access is not.
        try home.setMode(0o000, of: config)
        #expect(CopilotHomeAccessCheck.inspect(home: home.path).blocksCopilot)
    }

    @Test("A home that is only unwritable still has its children checked")
    func unwritableHomeStillChecksChildren() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)
        try home.setMode(0o555, of: home.path)

        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)

        #expect(report.problems.map(\.path) == [config, home.path])
        #expect(report.problems.map(\.access) == [.unreadable, .unwritable])
        #expect(report.blocksCopilot)
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .blocked)
        #expect(report.fixCommand.contains("'\(config)'"))
        #expect(report.fixCommand.contains("'\(home.path)'"))
    }

    @Test("A silent exit with only an unwritable entry keeps the generic diagnosis")
    func unwritableOnlyDoesNotExplainSilentExit() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        try home.makeDirectory("session-state", mode: 0o555)

        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", providerVersion: nil, stream: nil,
            copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: home.path) }
        )

        #expect(diagnostic.category == .providerProcessFailed)
    }

    @Test("An unreadable file Copilot never opens warns instead of blocking")
    func strayUnreadableFileOnlyWarns() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o600)
        let stray = try home.write("config.json.bak", mode: 0o000)

        let report = CopilotHomeAccessCheck.inspect(home: home.path)

        #expect(report.problems.map(\.path) == [stray])
        #expect(report.problems.first?.access == .unreadable)
        #expect(!report.blocksCopilot)
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .warning)
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", providerVersion: nil, stream: nil,
            copilotHomeAccess: { report }
        )
        #expect(diagnostic.category == .providerProcessFailed)
    }

    @Test("A Copilot home that is a file blocks and is moved aside")
    func fileInPlaceOfHomeBlocks() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let notAFolder = try home.write("copilot-home", mode: 0o600)

        let report = CopilotHomeAccessCheck.inspect(home: notAFolder)

        #expect(report.problems.map(\.access) == [.notADirectory])
        #expect(report.blocksCopilot)
        #expect(report.cause.contains("is a file, not a folder"))
        #expect(report.fixCommand == "mv '\(notAFolder)' '\(notAFolder).bak'")
        #expect(CopilotHomeAccessCheck.readinessCheck(for: report)?.state == .blocked)
    }

    @Test("The composer's cached readiness re-checks the Copilot home on every answer")
    func availabilityCacheRechecksHome() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o600)
        let service = RuntimeProviderAvailabilityService(readinessService: await Self.readyCopilotService(home: home.path))
        let cache = RuntimeReadinessStateCache()
        let configuration = RuntimeProviderAvailabilityConfiguration(
            claudePath: "", copilotPath: "", claudeProvider: .anthropic,
            vertexProjectID: "", vertexRegion: "", vertexOpusModel: "", vertexSonnetModel: "", vertexHaikuModel: ""
        )

        #expect(await service.states(configuration: configuration, cache: cache)[.copilotCLI] == .ready)

        try home.setMode(0o000, of: config)
        #expect(await service.states(configuration: configuration, cache: cache)[.copilotCLI] == .blocked)

        // The cache never stored the block, so the repair shows at once too.
        try home.setMode(0o600, of: config)
        #expect(await service.states(configuration: configuration, cache: cache)[.copilotCLI] == .ready)
        #expect(await cache.states(for: configuration, maxAge: 300)?[.copilotCLI] == .ready)
    }

    @Test("A cached launch verdict re-checks the Copilot home before it is trusted")
    func launchCacheRechecksHome() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o600)
        let service = await Self.readyCopilotService(home: home.path)
        let cache = RuntimeLaunchReadinessCache()

        let probed = await service.check(configuration: Self.copilotConfiguration)
        #expect(probed.state == .ready)
        await cache.record(probed.cacheable, for: Self.copilotConfiguration)

        try home.setMode(0o000, of: config)
        let hit = try #require(await cache.hit(for: Self.copilotConfiguration))
        let refreshed = service.refreshingUncachedChecks(hit.report, runtime: .copilotCLI)
        #expect(refreshed.state == .blocked)
        #expect(refreshed.checks.contains { $0.id == CopilotHomeAccessCheck.readinessCheckID })
        // A blocked report must never be what the cache keeps.
        #expect(!probed.cacheable.checks.contains { $0.id == CopilotHomeAccessCheck.readinessCheckID })
    }

    @Test("Once ownership is back, the rest of the fix command restores access")
    func fixCommandRestoresPermissionBits() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        try home.makeDirectory("session-state", mode: 0o555)
        let report = CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1)
        #expect(report.problems.count == 2)

        // The test already owns the entries, so the `sudo chown` step is the
        // one part it can skip; a chown alone would leave both still broken.
        let afterChown = report.fixCommand
            .components(separatedBy: " && ")
            .filter { !$0.hasPrefix("sudo chown") }
            .joined(separator: " && ")
        #expect(afterChown.contains("chmod"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", afterChown]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)

        #expect(CopilotHomeAccessCheck.inspect(home: home.path).isClean)
    }

    @Test("Copilot readiness reports Needs setup when its config is unreadable")
    func readinessBlocksOnUnreadableConfig() async throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.98\n", stderr: "")
        )
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { $0 == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" },
            copilotStateHome: home.path
        )

        let report = await service.check(configuration: Self.copilotConfiguration)

        #expect(report.state == .blocked)
        let check = try #require(report.checks.first { $0.id == "copilot-home-access" })
        #expect(check.state == .blocked)
        #expect(check.detail.contains("config.json"))
        #expect(check.remediation?.contains("chmod u+rw") == true)

        try home.setMode(0o600, of: (home.path as NSString).appendingPathComponent("config.json"))
        let repaired = await service.check(configuration: Self.copilotConfiguration)
        #expect(repaired.state == .ready)
        #expect(!repaired.checks.contains { $0.id == "copilot-home-access" })
    }

    @Test("A silent Copilot exit with an unreadable home names the cause and the fix")
    func silentExitNamesHomeAccessCause() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        let config = try home.write("config.json", mode: 0o000)
        let inspect = { CopilotHomeAccessCheck.inspect(home: home.path, currentUserID: getuid() + 1) }

        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 1,
            rawError: "",
            runOutput: "",
            providerVersion: "1.0.98",
            stream: nil,
            copilotHomeAccess: inspect
        )

        #expect(diagnostic.category == .providerHomeAccessDenied)
        #expect(diagnostic.userMessage.contains("config.json"))
        #expect(diagnostic.userMessage.contains("sudo chown \"$USER\":staff '\(config)'"))
        #expect(diagnostic.summarySource == .fallback)
        #expect(!diagnostic.redactedSummary.isEmpty)
        let payload = diagnostic.userFacingPayload(prefix: "Copilot exited with code 1.")
        #expect(!payload.contains("failed before ASTRA received a visible assistant response"))
        #expect(diagnostic.auditFields(phase: "start", stream: nil)["failure_category"] == "provider_home_access_denied")
        #expect(AgentRuntimeWorker.durableFailureStopReason(category: diagnostic.category).rawValue
            == "provider_home_access_denied")
    }

    @Test("Any provider evidence or a clean home keeps the existing classification")
    func homeAccessOnlyExplainsSilentFailures() throws {
        let home = try FakeCopilotHome()
        defer { home.remove() }
        try home.write("config.json", mode: 0o000)
        var inspections = 0
        let inspect = { () -> CopilotHomeAccessReport in
            inspections += 1
            return CopilotHomeAccessCheck.inspect(home: home.path)
        }

        let withStderr = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "Error: something else broke", providerVersion: nil, stream: nil,
            copilotHomeAccess: inspect
        )
        #expect(withStderr.category == .providerProcessFailed)
        #expect(inspections == 0)

        let withOutput = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", runOutput: "partial answer", providerVersion: nil, stream: nil,
            copilotHomeAccess: inspect
        )
        #expect(withOutput.category == .providerProcessFailed)
        #expect(inspections == 0)

        let healthy = try FakeCopilotHome()
        defer { healthy.remove() }
        try healthy.write("config.json", mode: 0o600)
        let clean = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI, model: "gpt-5", exitCode: 1,
            rawError: "", providerVersion: nil, stream: nil,
            copilotHomeAccess: { CopilotHomeAccessCheck.inspect(home: healthy.path) }
        )
        #expect(clean.category == .providerProcessFailed)
        #expect(clean.userMessage.contains("failed before ASTRA received a visible assistant response"))
    }

    /// A readiness service whose Copilot CLI probe always answers, so the
    /// home check alone decides the verdict.
    private static func readyCopilotService(home: String) async -> RuntimeReadinessService {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.98\n", stderr: "")
        )
        return RuntimeReadinessService(
            runner: runner,
            detectExecutable: { $0 == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" },
            copilotStateHome: home
        )
    }

    private static let copilotConfiguration = RuntimeReadinessConfiguration(
        runtime: .copilotCLI,
        claudePath: "",
        copilotPath: "",
        claudeProvider: .anthropic,
        vertexProjectID: "",
        vertexRegion: "",
        vertexOpusModel: "",
        vertexSonnetModel: "",
        vertexHaikuModel: ""
    )
}

/// A temp folder standing in for `~/.copilot`. `remove()` restores owner
/// permissions first so a mode-000 entry cannot leak a folder per run.
struct FakeCopilotHome {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-home-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, mode: Int) throws -> String {
        let file = (path as NSString).appendingPathComponent(name)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: file))
        try setMode(mode, of: file)
        return file
    }

    @discardableResult
    func makeDirectory(_ name: String, mode: Int) throws -> String {
        let directory = (path as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try setMode(mode, of: directory)
        return directory
    }

    func setMode(_ mode: Int, of target: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
    }

    func remove() {
        try? setMode(0o700, of: path)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            try? setMode(0o700, of: (path as NSString).appendingPathComponent(child))
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}
