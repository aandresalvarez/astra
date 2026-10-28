import Foundation
import Darwin
import MailToolSupport

/// Compatibility CLI. Only the shipped host-control relay talks to ASTRA;
/// no registry file, Keychain service or OAuth token is read by this process.
@main
struct StanfordMailTool {
    static func main() {
        do { try run() }
        catch { Darwin.exit(exitWithError(prefix: "stanford-mail", error: error, asJSON: true, code: 2)) }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 1, ["-h", "--help", "help"].contains(args[0]) {
            print("stanford-mail accounts|folders|search|get [--account ACCOUNT_ID] [--query TEXT] [--message-id ID] [--limit N]")
            return
        }
        guard !args.isEmpty, let executable = Bundle.main.executableURL else {
            throw ToolError("Choose accounts, folders, search or get.")
        }
        let relay = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("astra-host-control")
        guard FileManager.default.isExecutableFile(atPath: relay.path) else {
            throw ToolError("ASTRA's mail relay is unavailable. Rebuild or update ASTRA.")
        }
        let result = try runProcess(relay.path, arguments: ["mail"] + args, timeout: 150)
        guard let data = result.stdout.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("ASTRA could not deliver this task's mail response.")
        }
        if let error = reply["error"] as? [String: Any], let message = error["message"] as? String {
            throw ToolError(message)
        }
        guard result.exitCode == 0, let output = reply["result"] as? [String: Any],
              output["isError"] as? Bool != true,
              let content = output["content"] as? [[String: Any]], content.count == 1,
              let text = content[0]["text"] as? String, let payload = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: payload)) != nil else {
            throw ToolError("ASTRA could not read the approved mail account.")
        }
        print(text)
    }
}
