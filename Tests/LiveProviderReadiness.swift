import Foundation
@testable import ASTRA
import ASTRACore

enum LiveProviderReadiness {
    struct CommandResult: Equatable {
        var exitCode: Int
        var output: String
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        var runtimeID: AgentRuntimeID
        var message: String

        var description: String { message }
    }

    typealias CommandRunner = (_ executablePath: String, _ arguments: [String]) -> CommandResult

    static func requireReady(runtimeID: AgentRuntimeID, executablePath: String) throws {
        if let failure = check(runtimeID: runtimeID, executablePath: executablePath) {
            throw failure
        }
    }

    static func check(
        runtimeID: AgentRuntimeID,
        executablePath: String,
        runCommand: CommandRunner = run
    ) -> Failure? {
        switch runtimeID {
        case .openCodeCLI:
            let result = runCommand(executablePath, ["auth", "list"])
            guard result.exitCode == 0,
                  OpenCodeCLIRuntime.authListShowsConfiguredCredentials(result.output) else {
                let evidence = LiveProviderDiagnostics.redacted(String(result.output.prefix(500)))
                return Failure(
                    runtimeID: runtimeID,
                    message: "OpenCode CLI is installed but not authenticated for live E2E. Run `opencode auth login`, verify `opencode auth list` shows at least 1 credential, then rerun. Evidence: \(evidence)"
                )
            }
            return nil
        default:
            return nil
        }
    }

    private static func run(executablePath: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: Int(process.terminationStatus), output: output + error)
    }
}
