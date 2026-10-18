import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Additional provider startup state", .enabled(if: getuid() != 0))
struct RuntimeHomeAccessAdditionalStateTests {
    private let support = RuntimeHomeAccessEdgeCaseTests()

    @Test("The final host and container guards require the selected session to still exist",
          arguments: [AgentRuntimeID.copilotCLI, .antigravityCLI], [false, true])
    func selectedSessionDisappears(runtime: AgentRuntimeID, removeParent: Bool) async throws {
        let home = try support.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let value = request(runtime, home: home)
        let root = try #require(value.policy.roots.first)
        let state = try #require(root.resumedState)
        let session = "selected-session"
        let path = state.path(root: root.path(environment: value.environment, userHome: home, workingDirectory: home), sessionID: session)
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if state.isDirectory { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
        else { FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
        #expect(ProviderNativeSessionStore.lookup(runtime: runtime, sessionID: session, userHome: home, environment: value.environment) == .present)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: runtime, executablePath: "/unused/provider", arguments: [],
                                                currentDirectory: home, environment: value.environment,
                                                browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true)
        #expect(await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: session) == nil)
        #expect(try support.shell(runtime: runtime, home: home, resumeSessionID: session).exitCode == 0)

        // Reproduce deletion between native session selection and the final guard.
        try FileManager.default.removeItem(atPath: removeParent ? parent : path)
        let blocked = await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: session)
        #expect(blocked?.contains(path) == true)
        #expect(blocked?.contains("missing") == true)
        let container = try support.shell(runtime: runtime, home: home, resumeSessionID: session)
        #expect(container.exitCode == 78)
        #expect(container.stdout.isEmpty)
        #expect(container.stderr.contains(path))
        #expect(container.stderr.contains("missing"))
        #expect(!FileManager.default.fileExists(atPath: path))
        // A new conversation may still create its own state normally.
        #expect(await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: nil) == nil)
        #expect(try support.shell(runtime: runtime, home: home).exitCode == 0)
    }

    @Test("Copilot requires writable home session directory and database state", arguments: ["home", "sessions", "database", "wal", "shm"])
    func copilotMutableState(mode: String) async throws {
        let home = try support.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/.copilot"
        try FileManager.default.createDirectory(atPath: root + "/session-state", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/config.json", contents: Data(), attributes: [.posixPermissions: 0o400])
        for name in ["session-store.db", "session-store.db-wal", "session-store.db-shm"] {
            FileManager.default.createFile(atPath: root + "/" + name, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        let target = ["home": root, "sessions": root + "/session-state", "database": root + "/session-store.db",
                      "wal": root + "/session-store.db-wal", "shm": root + "/session-store.db-shm"][mode]!
        let directory = mode == "home" || mode == "sessions"
        defer { try? FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: target) }
        #expect(try support.shell(runtime: .copilotCLI, home: home).exitCode == 0)
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o555 : 0o400], ofItemAtPath: target)
        #expect(await RuntimeHomeAccessService.check(request(.copilotCLI, home: home))?.state == .blocked)
        let blocked = try support.shell(runtime: .copilotCLI, home: home)
        #expect(blocked.exitCode == 78)
        #expect(blocked.stdout.isEmpty)
    }

    @Test("Antigravity checks exactly the resumed conversation database")
    func antigravityResume() async throws {
        let home = try support.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = home + "/.gemini/antigravity-cli/conversations"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = directory + "/requested-session.db"
        FileManager.default.createFile(atPath: file, contents: Data(), attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: directory + "/unrelated-session.db", contents: Data(), attributes: [.posixPermissions: 0])
        var value = request(.antigravityCLI, home: home); value.resumeSessionID = "requested-session"
        #expect(await RuntimeHomeAccessService.check(value)?.state != .blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        #expect(await RuntimeHomeAccessService.check(value)?.state == .blocked)
        #expect(try support.shell(runtime: .antigravityCLI, home: home, resumeSessionID: "requested-session").exitCode == 78)
    }

    @Test("OpenCode checks only an explicitly selected extra config directory", arguments: ["directory", "file"])
    func openCodeConfigDirectory(mode: String) async throws {
        let home = try support.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let custom = home + "/custom config"
        try FileManager.default.createDirectory(atPath: custom, withIntermediateDirectories: true)
        let file = custom + "/opencode.json"
        FileManager.default.createFile(atPath: file, contents: Data(), attributes: [.posixPermissions: 0o400])
        FileManager.default.createFile(atPath: home + "/opencode.json", contents: Data(), attributes: [.posixPermissions: 0])
        #expect(await RuntimeHomeAccessService.check(request(.openCodeCLI, home: home))?.state != .blocked)
        var value = request(.openCodeCLI, home: home); value.environment["OPENCODE_CONFIG_DIR"] = custom
        #expect(await RuntimeHomeAccessService.check(value)?.state != .blocked)
        let target = mode == "directory" ? custom : file
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: custom) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: target)
        #expect(await RuntimeHomeAccessService.check(value)?.state == .blocked)
        #expect(try support.shell(runtime: .openCodeCLI, home: home, environment: value.environment).exitCode == 78)
    }

    @Test("OpenCode validates sidecars beside its effective database", arguments: ["-wal", "-shm"], ["read-only", "directory"])
    func openCodeSidecars(suffix: String, mode: String) async throws {
        let home = try support.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let database = home + "/custom.db"
        FileManager.default.createFile(atPath: database, contents: Data(), attributes: [.posixPermissions: 0o600])
        let sidecar = database + suffix
        if mode == "directory" { try FileManager.default.createDirectory(atPath: sidecar, withIntermediateDirectories: false) }
        else { FileManager.default.createFile(atPath: sidecar, contents: Data(), attributes: [.posixPermissions: 0o400]) }
        var value = request(.openCodeCLI, home: home); value.environment["OPENCODE_DB"] = database
        #expect(await RuntimeHomeAccessService.check(value)?.state == .blocked)
        #expect(try support.shell(runtime: .openCodeCLI, home: home, environment: value.environment).exitCode == 78)
    }

    @Test("OpenCode must own existing private database files", arguments: ["", "-wal", "-shm"])
    func openCodePrivateOwner(suffix: String) async throws {
        let home = try support.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = home + "/private.db" + suffix
        FileManager.default.createFile(atPath: file, contents: Data(), attributes: [.posixPermissions: 0o600])
        var value = request(.openCodeCLI, home: home)
        value.environment["OPENCODE_DB"] = home + "/private.db"
        #expect(await RuntimeHomeAccessService.check(value)?.state != .blocked)
        value.currentUserID = getuid() + 1
        let blocked = await RuntimeHomeAccessService.check(value)
        #expect(blocked?.state == .blocked)
        #expect(blocked?.detail.contains("owned by another user") == true)
    }

    @Test("Real Linux refuses inaccessible startup state before executing the provider",
          .enabled(if: ProcessInfo.processInfo.environment["ASTRA_LIVE_HOME_DOCKER"] == "1"),
          arguments: ["copilot-home", "copilot-sessions", "copilot-db", "copilot-wal", "copilot-shm", "antigravity-resume",
                      "opencode-config-root", "opencode-config-file", "opencode-wal", "opencode-shm", "opencode-foreign"])
    func realLinuxMutableState(mode: String) async throws {
        let image = try #require(ProcessInfo.processInfo.environment["ASTRA_HOME_SHELL_IMAGE"])
        let docker = try #require(DockerRuntimeResolver.resolve(environment: RuntimeProcessEnvironment.enriched()))
        let runtime: AgentRuntimeID = mode.hasPrefix("copilot") ? .copilotCLI : (mode.hasPrefix("antigravity") ? .antigravityCLI : .openCodeCLI)
        let target: String
        let directory: Bool
        switch mode {
        case "copilot-home": target = "/tmp/astra/.copilot"; directory = true
        case "copilot-sessions": target = "/tmp/astra/.copilot/session-state"; directory = true
        case "copilot-db": target = "/tmp/astra/.copilot/session-store.db"; directory = false
        case "copilot-wal": target = "/tmp/astra/.copilot/session-store.db-wal"; directory = false
        case "copilot-shm": target = "/tmp/astra/.copilot/session-store.db-shm"; directory = false
        case "antigravity-resume": target = "/tmp/astra/.gemini/antigravity-cli/conversations/requested.db"; directory = false
        case "opencode-config-root": target = "/tmp/astra/custom config"; directory = true
        case "opencode-config-file": target = "/tmp/astra/custom config/opencode.json"; directory = false
        case "opencode-shm": target = "/tmp/astra/custom.db-shm"; directory = false
        default: target = "/tmp/astra/custom.db-wal"; directory = false
        }
        let quote = RuntimeRemediationCatalog.shellQuoted
        let provider = RuntimeHomeAccessContainerCommand.command(runtime: runtime, executable: "/bin/echo", arguments: ["PROVIDER_REACHED"],
                                                                 resumeSessionID: runtime == .antigravityCLI ? "requested" : nil)
        let environment = "HOME=/tmp/astra OPENCODE_CONFIG_DIR='/tmp/astra/custom config' OPENCODE_DB=/tmp/astra/custom.db "
        let invoke = "su -s /bin/sh -p nobody -c " + quote(environment + provider.map(quote).joined(separator: " "))
        let setup = directory ? "mkdir -p \(quote(target)); chmod 777 \(quote(target))" :
            "mkdir -p \(quote((target as NSString).deletingLastPathComponent)); : > \(quote(target)); chmod 666 \(quote(target))"
        let deny = "chmod \(mode == "opencode-foreign" ? "666" : (directory ? "555" : "400")) \(quote(target))"
        let repair = directory ? "chmod 777 \(quote(target))" :
            (mode == "antigravity-resume" ? "chmod 666 \(quote(target))" : "rm \(quote(target))")
        // Config is read-only; lack of read/search access is its failure, not lack of write access.
        let unreadableConfig = mode.hasPrefix("opencode-config") || mode == "antigravity-resume"
        let script = """
        set -eu
        mkdir -p /tmp/astra
        chmod 777 /tmp/astra
        \(setup)
        chmod -R 777 /tmp/astra
        \(deny)
        \(unreadableConfig ? "chmod 000 " + quote(target) : "")
        set +e
        \(invoke) > /tmp/out 2>/tmp/err
        result=$?
        set -e
        [ "$result" = 78 ] && [ ! -s /tmp/out ] && grep -q 'ASTRA_PROVIDER_HOME_ACCESS_DENIED:' /tmp/err
        \(repair)
        \(invoke) > /tmp/out 2>/tmp/err
        grep -qx PROVIDER_REACHED /tmp/out
        echo PR516_LINUX_STATE_OK
        """
        let args = ["run", "--rm", "--pull", "never", "--network", "none", "--read-only", "--cap-drop", "ALL",
                    "--cap-add", "SETUID", "--cap-add", "SETGID", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:mode=1777",
                    "--", image, "/bin/sh", "-c", script]
        let result = await ProcessBinaryRunner().run(path: docker.executablePath, args: args, timeout: 20, environment: docker.environment)
        #expect(result.isSuccess, "\(mode): \(result.stderr)")
        #expect(result.stdout == "PR516_LINUX_STATE_OK\n")
    }

    @Test("Real Linux refuses a session removed after selection without creating replacement state",
          .enabled(if: ProcessInfo.processInfo.environment["ASTRA_LIVE_HOME_DOCKER"] == "1"),
          arguments: [AgentRuntimeID.copilotCLI, .antigravityCLI], [false, true])
    func realLinuxSelectedSessionDisappears(runtime: AgentRuntimeID, removeParent: Bool) async throws {
        let image = try #require(ProcessInfo.processInfo.environment["ASTRA_HOME_SHELL_IMAGE"])
        let docker = try #require(DockerRuntimeResolver.resolve(environment: RuntimeProcessEnvironment.enriched()))
        let policy = AgentRuntimeAdapterRegistry.homeAccessPolicy(for: runtime)
        let root = try #require(policy.roots.first)
        let state = try #require(root.resumedState)
        let path = state.path(root: root.path(environment: [:], userHome: "/tmp/astra", workingDirectory: "/tmp/astra"), sessionID: "selected-session")
        let parent = (path as NSString).deletingLastPathComponent
        let quote = RuntimeRemediationCatalog.shellQuoted
        func invoke(session: String?) -> String {
            let command = RuntimeHomeAccessContainerCommand.command(runtime: runtime, executable: "/bin/echo",
                                                                    arguments: ["PROVIDER_REACHED"], resumeSessionID: session)
            return "su -s /bin/sh -p nobody -c " + quote("HOME=/tmp/astra " + command.map(quote).joined(separator: " "))
        }
        let script = """
        set -eu
        mkdir -p \(quote(parent))
        \(state.isDirectory ? "mkdir " + quote(path) : ": > " + quote(path))
        chmod -R 777 /tmp/astra
        \(invoke(session: "selected-session")) > /tmp/out 2>/tmp/err
        grep -qx PROVIDER_REACHED /tmp/out
        rm -rf \(quote(removeParent ? parent : path))
        set +e
        \(invoke(session: "selected-session")) > /tmp/out 2>/tmp/err
        result=$?
        set -e
        [ "$result" = 78 ] && [ ! -s /tmp/out ] && grep -q 'Selected resumed state is missing:' /tmp/err
        [ ! -e \(quote(path)) ]
        \(invoke(session: nil)) > /tmp/out 2>/tmp/err
        grep -qx PROVIDER_REACHED /tmp/out
        [ ! -e \(quote(path)) ]
        echo PR516_LINUX_RESUME_OK
        """
        let args = ["run", "--rm", "--pull", "never", "--network", "none", "--read-only", "--cap-drop", "ALL",
                    "--cap-add", "SETUID", "--cap-add", "SETGID", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:mode=1777",
                    "--", image, "/bin/sh", "-c", script]
        let result = await ProcessBinaryRunner().run(path: docker.executablePath, args: args, timeout: 20, environment: docker.environment)
        #expect(result.isSuccess, "\(runtime): \(result.stderr)")
        #expect(result.stdout == "PR516_LINUX_RESUME_OK\n")
    }

    private func request(_ runtime: AgentRuntimeID, home: String) -> RuntimeHomeAccessRequest {
        .init(runtime: runtime, policy: AgentRuntimeAdapterRegistry.homeAccessPolicy(for: runtime), environment: ["HOME": home],
              workingDirectory: home, userHome: home)
    }
}
