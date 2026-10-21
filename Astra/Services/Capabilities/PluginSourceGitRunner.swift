import Foundation
import ASTRACore

/// Git alone runs in the resource-limited child. No PATH or shared tools
/// lookup can substitute the helper shipped with this build of ASTRA.
struct PluginSourceGitRunner: BinaryRunner {
    var helper: @Sendable () -> URL? = { bundledHelper() }
    var maximumOutputBytes = 8 * 1024 * 1024

    static var bundledHelperURL: URL {
        let root: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            root = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        } else {
            let resources = Bundle.module.bundleURL.deletingLastPathComponent()
            let testBundle = resources.deletingLastPathComponent().deletingLastPathComponent()
            // The Xcode SwiftPM builder embeds resources inside the xctest
            // bundle; executable products remain beside that bundle.
            root = testBundle.pathExtension == "xctest"
                ? testBundle.deletingLastPathComponent() : resources
        }
        return root.appendingPathComponent("astra-plugin-fetch")
    }

    static func bundledHelper() -> URL? {
        let url = bundledHelperURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func run(path: String, args: [String], timeout: TimeInterval, environment: [String: String]?) async -> RunResult {
        guard let helper = helper() else {
            return RunResult(outcome: .launchFailed("Plugin fetch resource helper is missing; rebuild ASTRA."), stdout: "", stderr: "")
        }
        return await ProcessBinaryRunner().run(path: helper.path, args: [path] + args,
            timeout: timeout, environment: environment, currentDirectory: nil,
            maximumOutputBytes: maximumOutputBytes, terminateProcessGroup: true, stopOnOutputLimit: true)
    }
}

/// Metadata is inspected before recursive tree traversal. Delta objects are
/// measured by Git's batch header (their final size, not the delta stream).
enum PluginSourceObjectBudget {
    static func admits(_ metadata: String, maximumObjects: Int, maximumBytes: Int) -> Bool {
        var total = 0
        var count = 0
        for line in metadata.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, ["blob", "tree", "commit", "tag"].contains(fields[1]),
                  let size = Int(fields[2]), size >= 0, size <= maximumBytes - total
            else { return false }
            total += size
            count += 1
            guard count <= maximumObjects else { return false }
        }
        return count > 0
    }
}
