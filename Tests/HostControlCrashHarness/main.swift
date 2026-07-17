import Foundation
import HostControlToolSupport

@main
struct HostControlCrashHarness {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data("missing supervised executable\n".utf8))
            Foundation.exit(64)
        }

        let result = HostControlProcessRunner(
            limits: HostControlProcessLimits(maximumTimeoutSeconds: 60, outputByteLimit: 1_024)
        ).run(
            executablePath: CommandLine.arguments[1],
            arguments: Array(CommandLine.arguments.dropFirst(2)),
            timeoutSeconds: 60,
            environment: [:]
        )
        Foundation.exit(result.exitCode)
    }
}
