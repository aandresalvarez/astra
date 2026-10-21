import Foundation
import WorkspaceToolSupport

@main
struct AstraWorkspaceJobTool {
    static func main() {
        let output = RemoteWorkspaceJobCLI.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment
        )
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
        FileHandle.standardError.write(Data(output.stderr.utf8))
        exit(output.exitCode)
    }
}
