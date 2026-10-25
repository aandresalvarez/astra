import Foundation
import ASTRACore

/// Apple's /usr/bin/git is a developer-tool launcher. Resolve the selected
/// tool without running Git, then put the real binary under the fetch limits.
/// Loading Xcode's launcher frameworks under that limit is not Git work.
enum PluginSourceGitExecutable {
    static func lookup(timeout: TimeInterval) async -> RunResult {
        await ProcessBinaryRunner().run(path: "/usr/bin/xcrun", args: ["--find", "git"],
            timeout: timeout, environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil,
            maximumOutputBytes: 4_096, terminateProcessGroup: true, stopOnOutputLimit: true)
    }

    static func path(from result: RunResult) -> String? {
        guard result.isSuccess, !result.stdoutTruncated, !result.stderrTruncated else { return nil }
        let selected = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.hasPrefix("/"), (selected as NSString).lastPathComponent == "git",
              !selected.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let path = URL(fileURLWithPath: selected).standardizedFileURL.resolvingSymlinksInPath().path
        guard path != "/usr/bin/git", FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
