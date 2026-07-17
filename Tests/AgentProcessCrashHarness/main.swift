import ASTRA
import Foundation

@main
struct AgentProcessCrashHarness {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: astra-agent-process-crash-harness executable [arguments...]\n".utf8))
            Foundation.exit(64)
        }

        let process = AgentExecutionScopedProcess(
            executablePath: CommandLine.arguments[1],
            arguments: Array(CommandLine.arguments.dropFirst(2)),
            currentDirectory: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment
        )
        try process.run()

        // Keep the owning process alive without installing signal handlers.
        // Crash tests SIGKILL this harness so only kernel pipe EOF can notify
        // the out-of-process watchdog.
        withExtendedLifetime(process) {
            dispatchMain()
        }
    }
}
