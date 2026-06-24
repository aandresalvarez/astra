import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Browser Tool Shim")
@MainActor
struct BrowserToolShimTests {
    @Test("Task-local astra-browser shim injects bridge endpoint and leaves token in process env")
    func taskLocalShimInjectsEndpointAndLeavesTokenInProcessEnv() throws {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-browser-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let realTool = root.appendingPathComponent("real-astra-browser")
        try """
        #!/bin/sh
        printf '%s|%s|%s' "$ASTRA_BROWSER_URL" "$ASTRA_BROWSER_TOKEN" "$ASTRA_BROWSER_REQUIRED_ENGINE"
        """.write(to: realTool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: realTool.path)

        let workspace = Workspace(name: "Browser Shim", primaryPath: root.path)
        context.insert(workspace)
        let task = AgentTask(title: "Use browser", goal: "Read page", workspace: workspace)
        context.insert(task)
        try context.save()

        let endpoint = "http://127.0.0.1:59638"
        let shimDirectory = try #require(AgentRuntimeProcessRunner.prepareBrowserToolShimIfNeeded(
            task: task,
            taskEnv: [
                "ASTRA_BROWSER_URL": endpoint,
                "ASTRA_BROWSER_TOKEN": "ASTRA_TEST_BROWSER_TOKEN",
                "ASTRA_BROWSER_REQUIRED_ENGINE": "controlled-cdp"
            ],
            realToolPath: realTool.path
        ))
        let shimPath = (shimDirectory as NSString).appendingPathComponent("astra-browser")
        #expect(FileManager.default.isExecutableFile(atPath: shimPath))
        let shimAttributes = try FileManager.default.attributesOfItem(atPath: shimPath)
        let shimDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: shimDirectory)
        #expect((shimAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((shimDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shimPath)
        process.environment = [
            "ASTRA_BROWSER_TOKEN": "ASTRA_TEST_BROWSER_TOKEN"
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let script = try String(contentsOfFile: shimPath, encoding: .utf8)
        #expect(process.terminationStatus == 0)
        #expect(text == "\(endpoint)|ASTRA_TEST_BROWSER_TOKEN|controlled-cdp")
        #expect(!script.contains("ASTRA_TEST_BROWSER_TOKEN"))
        #expect(!script.contains("ASTRA_BROWSER_TOKEN"))
    }

    @Test("Remote workspace ssh shim uses task-scoped known hosts")
    func remoteWorkspaceSSHShimUsesTaskScopedKnownHosts() throws {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-ssh-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fakeSSH = root.appendingPathComponent("real-ssh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@"
        """.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let hostKnownHosts = root.appendingPathComponent("host-known-hosts")
        try "deid-jsn-workbench ssh-ed25519 AAAA\n".write(to: hostKnownHosts, atomically: true, encoding: .utf8)

        let workspace = Workspace(name: "Remote Shim", primaryPath: root.path)
        context.insert(workspace)
        SSHConnectionManager.save([
            SSHConnection(
                name: "deid-jsn-workbench",
                host: "deid-jsn-workbench",
                user: "alvaro1",
                keyPath: "~/.ssh/google_compute_engine",
                configAlias: "deid-jsn-workbench"
            )
        ], workspacePath: root.path)
        let task = AgentTask(title: "Use ssh", goal: "ssh into remote", workspace: workspace)
        context.insert(task)
        try context.save()

        let shimDirectory = try #require(AgentRuntimeProcessRunner.prepareSSHShimIfNeeded(
            task: task,
            realSSHPath: fakeSSH.path,
            hostKnownHostsPath: hostKnownHosts.path
        ))
        let shimPath = (shimDirectory as NSString).appendingPathComponent("ssh")
        let knownHostsPath = (TaskWorkspaceAccess(task: task).taskFolder as NSString)
            .appendingPathComponent(".runtime-ssh/known_hosts")
        #expect(FileManager.default.isExecutableFile(atPath: shimPath))
        #expect(FileManager.default.fileExists(atPath: knownHostsPath))
        #expect(try String(contentsOfFile: knownHostsPath, encoding: .utf8) == "deid-jsn-workbench ssh-ed25519 AAAA\n")

        let script = try String(contentsOfFile: shimPath, encoding: .utf8)
        #expect(script.contains("UserKnownHostsFile="))
        #expect(script.contains(knownHostsPath))
        #expect(!script.contains(hostKnownHosts.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shimPath)
        process.arguments = ["deid-jsn-workbench", "hostname"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
        #expect(process.terminationStatus == 0)
        #expect(Array(lines.prefix(8)) == [
            "-o",
            "UserKnownHostsFile=\(knownHostsPath)",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "CheckHostIP=no"
        ])
        #expect(Array(lines.suffix(2)) == ["deid-jsn-workbench", "hostname"])
    }
}
