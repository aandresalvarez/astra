import Testing
import Foundation
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Regression coverage for the argv shape that killed a production Copilot run:
/// a pasted `.txt` attachment reached `--add-dir`, which only accepts a
/// directory, so the CLI exited 1 before emitting a single token.
@Suite("Provider Native Directory Projection")
struct ProviderNativeDirectoryProjectionTests {
    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-native-dirs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("attachment".utf8).write(to: url)
        return url.path
    }

    @Test("An input file inside a granted root is dropped, not forwarded as a directory")
    func inputFileInsideGrantedRootIsDropped() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let paste = try writeFile("astra_paste_E9EC2AF4.txt", in: inputs)

        let projection = ProviderNativeDirectoryProjection.project(
            resourcePaths: [paste],
            alreadyReachableDirectories: [root.path]
        )

        #expect(projection.additionalDirectories.isEmpty)
        #expect(projection.unreachableFiles.isEmpty)
    }

    @Test("An input file outside every granted root is reported, never widened to its parent")
    func inputFileOutsideGrantedRootsIsReported() throws {
        let granted = try makeSandbox()
        let elsewhere = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: granted)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let attachment = try writeFile("spec.pdf", in: elsewhere)

        let projection = ProviderNativeDirectoryProjection.project(
            resourcePaths: [attachment],
            alreadyReachableDirectories: [granted.path]
        )

        // Widening to the parent would hand `--add-dir` write access to every
        // sibling of the attachment, so the file is surfaced instead.
        #expect(projection.additionalDirectories.isEmpty)
        #expect(projection.unreachableFiles == [attachment])
    }

    @Test("Directories outside the granted roots are still forwarded once")
    func directoriesOutsideGrantedRootsAreForwarded() throws {
        let granted = try makeSandbox()
        let extra = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: granted)
            try? FileManager.default.removeItem(at: extra)
        }
        let nested = granted.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let projection = ProviderNativeDirectoryProjection.project(
            resourcePaths: [extra.path, extra.path, nested.path],
            alreadyReachableDirectories: [granted.path]
        )

        #expect(projection.additionalDirectories == [extra.path])
        #expect(projection.unreachableFiles.isEmpty)
    }

    @Test("Directory candidates drop existing files and keep paths that do not exist yet")
    func directoryCandidatesDropFilesButKeepUncreatedPaths() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile("notes.txt", in: root)
        let notYetCreated = root.appendingPathComponent("created-during-the-run").path

        let candidates = ProviderNativeDirectoryProjection.directoryCandidates(
            [root.path, file, notYetCreated]
        )

        #expect(candidates == [root.path, notYetCreated])
    }

    @Test("Copilot never renders an existing file as an --add-dir value")
    func copilotSkipsFileAdditionalPaths() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let paste = try writeFile("astra_paste_E9EC2AF4.txt", in: root)
        let capabilities = CopilotCLICapabilities(helpText: "--output-format=FORMAT --no-ask-user")

        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: "/bin/copilot",
            prompt: "Do work",
            model: "gpt-5.6-sol",
            workspacePath: "/tmp/ws",
            additionalPaths: [root.path, paste],
            permissionPolicy: .autonomous,
            allowedTools: [],
            timeoutSeconds: 60,
            capabilities: capabilities,
            taskEnvironment: [:],
            copilotHome: "/tmp/copilot-home",
            permissionArguments: ProviderPolicyRender.copilotLaunchPermissionArguments(
                policy: .autonomous,
                allowedTools: [],
                capabilities: capabilities,
                localToolCommands: [],
                runtimeSupportTools: [],
                allowAllPathsForSSHConnections: false
            )
        )

        #expect(!plan.arguments.contains(paste))
        #expect(addDirValues(in: plan.arguments) == [root.path])
    }

    @Test("Antigravity never renders an existing file as an --add-dir value")
    func antigravitySkipsFileAdditionalPaths() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try writeFile("context.md", in: root)

        let plan = AntigravityCLIRuntime.buildCommand(
            executablePath: "/bin/agy",
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: [root.path, attachment],
            permissionPolicy: .restricted,
            timeoutSeconds: 45,
            taskEnvironment: [:],
            pathPrefix: [],
            includeAstraToolsPath: false,
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted)
        )

        #expect(!plan.arguments.contains(attachment))
        #expect(addDirValues(in: plan.arguments) == [root.path])
    }

    @Test("A pasted task input never reaches Copilot's --add-dir list")
    func pastedTaskInputIsProjectedAwayFromAddDir() throws {
        let workspaceRoot = try makeSandbox()
        let outside = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: outside)
        }
        let paste = try writeFile("astra_paste_E9EC2AF4.txt", in: workspaceRoot)
        let detached = try writeFile("spec.pdf", in: outside)

        let task = AgentTask(title: "Research pass", goal: "Do not run any code")
        task.workspace = Workspace(name: "Test", primaryPath: workspaceRoot.path)
        task.inputs = [paste, detached]

        let projection = AgentRuntimeProcessRunner.copilotNativeDirectoryProjection(for: task)

        #expect(!projection.additionalDirectories.contains(paste))
        #expect(!projection.additionalDirectories.contains(detached))
        #expect(projection.additionalDirectories.contains(workspaceRoot.path))
        // The paste sits under the workspace root that is already granted; the
        // detached attachment has no covering root and is surfaced instead.
        #expect(projection.unreachableFiles == [detached])
    }

    private func addDirValues(in arguments: [String]) -> [String] {
        arguments.indices
            .filter { arguments[$0] == "--add-dir" && $0 + 1 < arguments.count }
            .map { arguments[$0 + 1] }
    }
}
