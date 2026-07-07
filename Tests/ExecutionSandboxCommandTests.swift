import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// `ExecutionSandbox.decideForCommand` — the non-agent Seatbelt entry point used
/// by the task-validation harness (`pytest`/`npm test`/`swift test`/`xcodebuild`/
/// `make test`, gated upstream by `ValidationCommandPolicy`). Unlike `decide()`,
/// this always floors `.off` to `.bestEffort` and always uses the open (write-only)
/// read scope — these tests pin both of those deliberately-different behaviors.
@Suite("Execution Sandbox — Non-agent commands")
struct ExecutionSandboxCommandTests {
    private func makeWorkspace() throws -> (root: URL, workspace: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-cmd-sandbox-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (root, workspace)
    }

    // MARK: - Enforcement floor

    @Test("Off enforcement still applies (floored to best-effort), not skipped")
    func offEnforcementFloorsToApplied() throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let decision = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "true"],
            currentDirectory: workspace.path,
            environment: [:],
            homeDirectory: root.appendingPathComponent("home").path,
            homeWritableRelativePaths: [],
            settings: ExecutionSandboxSettings(enforcement: .off)
        )
        guard case .applied = decision else {
            Issue.record("Expected .applied even with enforcement .off (validation always gets a floor), got \(decision)")
            return
        }
    }

    // MARK: - Unavailable branches: floored enforcement still maps strict/best-effort correctly

    @Test("Empty workspace path falls back (floored) or fails closed (explicit strict)")
    func emptyWorkspaceUnavailable() throws {
        let bestEffort = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "true"],
            currentDirectory: "",
            environment: [:],
            homeWritableRelativePaths: [],
            settings: ExecutionSandboxSettings(enforcement: .off)
        )
        #expect(bestEffort == .fallback(reason: "no_execution_path"))

        let strict = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "true"],
            currentDirectory: "",
            environment: [:],
            homeWritableRelativePaths: [],
            settings: ExecutionSandboxSettings(enforcement: .strict)
        )
        #expect(strict == .failClosed(reason: "no_execution_path"))
    }

    @Test("An overly broad workspace root is refused, not wrapped into a no-op sandbox")
    func unsafeWorkspaceRootUnavailable() throws {
        for broad in ["/", "/usr", "/Users"] {
            let strict = ExecutionSandbox.decideForCommand(
                executablePath: "/bin/zsh",
                arguments: ["-c", "true"],
                currentDirectory: broad,
                environment: [:],
                homeWritableRelativePaths: [],
                settings: ExecutionSandboxSettings(enforcement: .strict)
            )
            #expect(strict == .failClosed(reason: "unsafe_execution_path"))
        }
    }

    @Test("Missing sandbox-exec falls back (floored best-effort) or fails closed (strict)")
    func missingSandboxExecUnavailable() throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = StubCommandExecutableFileManager(executableExists: false)

        let bestEffort = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "true"],
            currentDirectory: workspace.path,
            environment: [:],
            homeWritableRelativePaths: [],
            settings: ExecutionSandboxSettings(enforcement: .off),
            fileManager: absent
        )
        #expect(bestEffort == .fallback(reason: "sandbox_exec_missing"))

        let strict = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "true"],
            currentDirectory: workspace.path,
            environment: [:],
            homeWritableRelativePaths: [],
            settings: ExecutionSandboxSettings(enforcement: .strict),
            fileManager: absent
        )
        #expect(strict == .failClosed(reason: "sandbox_exec_missing"))
    }

    // MARK: - Applied profile shape

    @Test("Applied decision grants the workspace, /tmp, and each home-relative tool-cache path")
    func appliedGrantsWorkspaceTmpAndToolCaches() throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = root.appendingPathComponent("home")

        let decision = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "swift test"],
            currentDirectory: workspace.path,
            environment: [:],
            homeDirectory: fakeHome.path,
            homeWritableRelativePaths: [".swiftpm", "Library/Developer/Xcode/DerivedData"],
            settings: ExecutionSandboxSettings(enforcement: .bestEffort)
        )
        guard case .applied(_, _, let writableRoots) = decision else {
            Issue.record("Expected .applied, got \(decision)")
            return
        }
        let canonicalWorkspace = ExecutionSandbox.canonicalize(workspace.path)
        #expect(writableRoots.contains { $0 == canonicalWorkspace })
        #expect(writableRoots.contains { $0 == "/tmp" || $0 == "/private/tmp" })
        #expect(writableRoots.contains { $0.hasSuffix("/home/.swiftpm") })
        #expect(writableRoots.contains { $0.hasSuffix("/home/Library/Developer/Xcode/DerivedData") })
    }

    @Test("Applied profile keeps the privacy-root deny active despite the open read scope")
    func appliedKeepsPrivacyDenyInOpenScope() throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let decision = ExecutionSandbox.decideForCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", "true"],
            currentDirectory: workspace.path,
            environment: [:],
            homeWritableRelativePaths: [],
            settings: ExecutionSandboxSettings(enforcement: .bestEffort)
        )
        guard case .applied(_, let arguments, _) = decision else {
            Issue.record("Expected .applied, got \(decision)")
            return
        }
        let profileIndex = arguments.firstIndex(of: "-p").map { $0 + 1 }
        #expect(profileIndex != nil)
        guard let profileIndex else { return }
        let profile = arguments[profileIndex]

        // The privacy-root deny is unconditional (not gated by read scope) —
        // present even though this path always uses .open.
        #expect(profile.contains("(subpath (param \"PROTECTED_READ_ROOT_0\"))"))
        // But this is genuinely .open: no read-restricting rule was added.
        #expect(!profile.contains("(debug deny file-read*)"))
        #expect(!profile.contains("\n(deny file-read*)\n"))
    }

    @Test("allowNetwork setting controls the network-deny profile line")
    func networkDenyShapeMatchesSettings() throws {
        let (root, workspace) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        func profile(allowNetwork: Bool) throws -> String {
            let decision = ExecutionSandbox.decideForCommand(
                executablePath: "/bin/zsh",
                arguments: ["-c", "true"],
                currentDirectory: workspace.path,
                environment: [:],
                homeWritableRelativePaths: [],
                settings: ExecutionSandboxSettings(enforcement: .bestEffort, allowNetwork: allowNetwork)
            )
            guard case .applied(_, let arguments, _) = decision, let index = arguments.firstIndex(of: "-p") else {
                Issue.record("Expected .applied with a profile, got \(decision)")
                return ""
            }
            return arguments[index + 1]
        }

        #expect(try profile(allowNetwork: true).contains("(deny network*)") == false)
        #expect(try profile(allowNetwork: false).contains("(deny network*)"))
    }

    // MARK: - Integration: real kernel boundary

    @Test("Seatbelt confines writes to the workspace and granted tool-cache paths, blocks everything else under the fake home")
    func liveConfinesWritesToWorkspaceAndGrantedToolCaches() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let (root, workspace) = try makeWorkspace()
        defer { try? fm.removeItem(at: root) }
        let fakeHome = root.appendingPathComponent("home")
        try fm.createDirectory(at: fakeHome.appendingPathComponent(".fake-tool-cache"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeHome.appendingPathComponent("not-granted"), withIntermediateDirectories: true)

        // Decide fresh per probe (rather than slicing/reconstructing one argv)
        // so each script is exactly what decideForCommand would produce for it —
        // no off-by-one risk in hand-splicing the wrapped argument vector.
        func runConfinedShell(_ script: String) -> Int32 {
            let decision = ExecutionSandbox.decideForCommand(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                currentDirectory: workspace.path,
                environment: [:],
                homeDirectory: fakeHome.path,
                homeWritableRelativePaths: [".fake-tool-cache"],
                settings: ExecutionSandboxSettings(enforcement: .bestEffort)
            )
            guard case .applied(let executablePath, let arguments, _) = decision else {
                Issue.record("Expected .applied, got \(decision)")
                return -1
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Issue.record("Failed to launch sandbox-exec: \(error)")
                return -1
            }
            process.waitUntilExit()
            return process.terminationStatus
        }

        let insidePath = workspace.appendingPathComponent("inside.txt").path
        let grantedCachePath = fakeHome.appendingPathComponent(".fake-tool-cache/cache.txt").path
        let notGrantedPath = fakeHome.appendingPathComponent("not-granted/probe.txt").path

        #expect(runConfinedShell("printf astra > '\(insidePath)'") == 0)
        #expect(fm.fileExists(atPath: insidePath))

        #expect(runConfinedShell("printf astra > '\(grantedCachePath)'") == 0)
        #expect(fm.fileExists(atPath: grantedCachePath))

        #expect(runConfinedShell("printf escape > '\(notGrantedPath)'") != 0)
        #expect(!fm.fileExists(atPath: notGrantedPath))
    }
}

private final class StubCommandExecutableFileManager: FileManager {
    let executableExists: Bool
    init(executableExists: Bool) {
        self.executableExists = executableExists
        super.init()
    }
    override func isExecutableFile(atPath path: String) -> Bool { executableExists }
}
