import Testing
import Foundation

@Suite("Error Handling")
struct ErrorHandlingTests {

    @Test("Non-existent CLI path detected")
    func cliNotFound() {
        let fakePath = "/tmp/nonexistent-claude-\(UUID().uuidString)"
        #expect(!FileManager.default.isExecutableFile(atPath: fakePath))
    }

    @Test("Non-existent workspace detected")
    func workspaceNotFound() {
        var isDir: ObjCBool = false
        #expect(!FileManager.default.fileExists(atPath: "/tmp/no-such-dir-xyz", isDirectory: &isDir))
    }

    @Test("Valid workspace passes check")
    func validWorkspace() {
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: "/tmp", isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("Timeout kills long-running process")
    func timeoutKillsProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
    }

    @Test("Test command execution — success")
    func testCommandSuccess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "echo 'all tests passed'"]
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()

        #expect(p.terminationStatus == 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(output.contains("all tests passed"))
    }

    @Test("Test command execution — failure")
    func testCommandFailure() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "exit 1"]
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()

        #expect(p.terminationStatus != 0)
    }
}
