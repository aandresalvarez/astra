import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Browser Tool Shim")
@MainActor
struct BrowserToolShimTests {
    @Test("Task-local astra-browser shim injects bridge endpoint and token")
    func taskLocalShimInjectsEndpointAndToken() throws {
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
        printf '%s|%s' "$ASTRA_BROWSER_URL" "$ASTRA_BROWSER_TOKEN"
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
            taskEnv: ["ASTRA_BROWSER_URL": endpoint, "ASTRA_BROWSER_TOKEN": "ASTRA_TEST_BROWSER_TOKEN"],
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
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(text == "\(endpoint)|ASTRA_TEST_BROWSER_TOKEN")
    }
}
