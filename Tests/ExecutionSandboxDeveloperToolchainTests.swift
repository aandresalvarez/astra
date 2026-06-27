import Foundation
import Testing
@testable import ASTRA

/// The developer-toolchain carve-out: sandboxed providers run Apple tool shims
/// (`/usr/bin/git`, `clang`, …) that resolve through `xcode-select`/`DEVELOPER_DIR`.
/// If the profile can't read the active developer directory the shim shows the
/// system "install command line developer tools" dialog even when they're
/// installed — and when that directory is Xcode under `/Applications`, the privacy
/// deny on `/Applications` is what blocks it. These verify the sandbox keeps the
/// toolchain reachable wherever it lives.
@Suite("Execution Sandbox — Developer Toolchain")
struct ExecutionSandboxDeveloperToolchainTests {
    private func makePlan(
        currentDirectory: String,
        environment: [String: String]
    ) -> AgentRuntimeProcessLaunchPlan {
        AgentRuntimeProcessLaunchPlan(
            runtime: .copilotCLI,
            executablePath: "/opt/homebrew/bin/copilot",
            arguments: ["--version"],
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: true
        )
    }

    // MARK: - Resolver

    @Test("activeDeveloperDirectory honors an explicit DEVELOPER_DIR that exists")
    func resolverHonorsExplicitDeveloperDir() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("astra-dev-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let resolved = ExecutionSandbox.activeDeveloperDirectory(environment: ["DEVELOPER_DIR": dir.path])
        #expect(resolved == dir.path)
    }

    @Test("activeDeveloperDirectory ignores a non-existent DEVELOPER_DIR and falls back")
    func resolverIgnoresMissingDeveloperDir() {
        let resolved = ExecutionSandbox.activeDeveloperDirectory(environment: ["DEVELOPER_DIR": "/no/such/xcode"])
        #expect(resolved != "/no/such/xcode")
        // On any machine with Xcode or the standalone CLT, the fallback resolves.
        let hasToolchain = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools")
            || ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) != nil)
        if hasToolchain {
            #expect(resolved != nil)
        }
    }

    // MARK: - Privacy re-allow

    @Test("An Xcode toolchain is granted at the .app bundle and re-allowed past the privacy deny")
    func xcodeToolchainGrantedAtBundle() {
        // The shim validates the bundle (Info.plist next to Contents/Developer), so
        // the grant must widen from Contents/Developer to the whole .app.
        let grantRoot = ExecutionSandbox.developerToolchainGrantRoot("/Applications/Xcode.app/Contents/Developer")
        #expect(grantRoot == "/Applications/Xcode.app")
        let reAllow = ExecutionSandbox.protectedReadAllowRoots(
            explicitReadRoots: [grantRoot],
            protectedReadRoots: ExecutionSandbox.protectedReadRoots()
        )
        #expect(reAllow.contains("/Applications/Xcode.app"))
    }

    @Test("The standalone Command Line Tools dir is granted as-is and needs no protected re-allow")
    func commandLineToolsNeedsNoReAllow() {
        let clt = "/Library/Developer/CommandLineTools"
        #expect(ExecutionSandbox.developerToolchainGrantRoot(clt) == clt)
        let reAllow = ExecutionSandbox.protectedReadAllowRoots(
            explicitReadRoots: [clt],
            protectedReadRoots: ExecutionSandbox.protectedReadRoots()
        )
        #expect(!reAllow.contains(clt))
    }

    // MARK: - Decision wiring

    @Test("Strict decision grants the resolved developer dir as a readable root")
    func strictDecisionGrantsDeveloperReadRoot() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let workspace = fm.temporaryDirectory.appendingPathComponent("astra-ws-\(UUID().uuidString)")
        let developer = fm.temporaryDirectory.appendingPathComponent("astra-devdir-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createDirectory(at: developer, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace); try? fm.removeItem(at: developer) }

        let plan = makePlan(
            currentDirectory: workspace.path,
            environment: ["HOME": workspace.path, "DEVELOPER_DIR": developer.path]
        )
        let decision = ExecutionSandbox.decide(
            plan: plan,
            providerHomeDirectory: workspace.path,
            settings: ExecutionSandboxSettings(enforcement: .strict, allowNetwork: true, readScope: .enforce)
        )
        guard case .applied(let wrapped, _) = decision else {
            Issue.record("Expected strict sandbox to apply, got \(decision)")
            return
        }
        let canonicalDeveloper = ExecutionSandbox.canonicalize(developer.path) ?? developer.path
        #expect(wrapped.arguments.contains { $0.hasPrefix("READ_ROOT_") && $0.hasSuffix("=\(canonicalDeveloper)") })
        // An explicitly-set DEVELOPER_DIR is preserved into the wrapped environment.
        #expect(wrapped.environment["DEVELOPER_DIR"] == developer.path)
    }

    @Test("Applied decision pins DEVELOPER_DIR when the plan does not set one")
    func appliedDecisionPinsDeveloperDir() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let workspace = fm.temporaryDirectory.appendingPathComponent("astra-ws-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        let plan = makePlan(currentDirectory: workspace.path, environment: ["HOME": workspace.path])
        let decision = ExecutionSandbox.decide(
            plan: plan,
            providerHomeDirectory: workspace.path,
            settings: ExecutionSandboxSettings(enforcement: .strict, allowNetwork: true, readScope: .enforce)
        )
        guard case .applied(let wrapped, _) = decision else {
            Issue.record("Expected strict sandbox to apply, got \(decision)")
            return
        }
        // The sandbox pins whatever the host resolves (Xcode or CLT); if the host
        // has no toolchain at all, there is nothing to pin.
        let resolved = ExecutionSandbox.activeDeveloperDirectory(environment: plan.environment)
        #expect(wrapped.environment["DEVELOPER_DIR"] == resolved)
    }

    // MARK: - Kernel-level proof

    /// Runs Apple's `/usr/bin/git` shim through the *real* generated strict profile.
    /// On a host whose `xcode-select` points at Xcode under `/Applications`, this is
    /// exactly the path that used to hit the "install command line developer tools"
    /// dialog: the shim must resolve and read the toolchain inside the sandbox and
    /// exit cleanly. No `DEVELOPER_DIR` is preset, so the sandbox does the work.
    @Test("Strict sandbox runs the git shim without falling back to the install prompt")
    func strictSandboxRunsGitShim() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath),
              fm.isExecutableFile(atPath: "/usr/bin/git") else { return }

        let workspace = fm.temporaryDirectory.appendingPathComponent("astra-git-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        let plan = makePlan(currentDirectory: workspace.path, environment: ["HOME": workspace.path])
        // Only meaningful when the host actually has a resolvable toolchain.
        guard ExecutionSandbox.activeDeveloperDirectory(environment: plan.environment) != nil else { return }

        // Mirror the real provider environment: launchd always sets TMPDIR, and the
        // toolchain shim writes its `xcrun_db` cache into that per-user temp dir,
        // which `writableRoots` grants. (`RuntimeProcessEnvironment.enriched` carries
        // TMPDIR through from the app's process environment.)
        let gitPlan = AgentRuntimeProcessLaunchPlan(
            runtime: .copilotCLI,
            executablePath: "/usr/bin/git",
            arguments: ["--version"],
            currentDirectory: workspace.path,
            environment: ["HOME": workspace.path, "TMPDIR": fm.temporaryDirectory.path],
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: true
        )
        let decision = ExecutionSandbox.decide(
            plan: gitPlan,
            providerHomeDirectory: workspace.path,
            settings: ExecutionSandboxSettings(enforcement: .strict, allowNetwork: false, readScope: .enforce)
        )
        guard case .applied(let wrapped, _) = decision else {
            Issue.record("Expected strict sandbox to apply, got \(decision)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapped.executablePath)
        process.arguments = wrapped.arguments
        process.environment = wrapped.environment
        process.currentDirectoryURL = workspace
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
            + err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(data: data, encoding: .utf8) ?? "").lowercased()

        #expect(process.terminationStatus == 0, "git under sandbox exited \(process.terminationStatus): \(output)")
        #expect(output.contains("git version"))
        // The failure signature we're guarding against: the shim giving up on the toolchain.
        #expect(!output.contains("no developer tools"))
        #expect(!output.contains("xcode-select"))
    }
}
