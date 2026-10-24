import Foundation
import ASTRACore

/// The GitHub host `gh` infers from a checkout: a bare `gh pr list` inside a
/// clone of an Enterprise repository talks to that Enterprise host, not
/// github.com (`gh help environment`: `GH_HOST` applies only where the host
/// "cannot be inferred from the context of a local Git repository").
///
/// Read offline and fast: one `git config --local` of the checkout's remote
/// URLs, with no system or global configuration and none of the repository
/// scoping variables ASTRA may have inherited (`GitLocalEnvironment`), so
/// nothing but `.git/config` is read and no hook, filter or fsmonitor runs.
/// Fails closed: nil when it is not a checkout, git fails, a URL rewrite
/// (`url.*.insteadOf`) could change where a remote points, a host looks like
/// an SSH alias (no dot), or the remotes name more than one host.
enum GitHubCheckoutHost {
    static func host(workingDirectory: String, runner: BinaryRunner = ProcessBinaryRunner()) async -> String? {
        var environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = await runner.run(
            path: "/usr/bin/git",
            args: ["-C", workingDirectory, "config", "--local", "--null", "--get-regexp", #"^(remote\..*\.url|url\..*)$"#],
            timeout: 3,
            environment: environment
        )
        guard result.isSuccess else { return nil }
        return host(fromConfig: result.stdout)
    }

    /// The one host the `--null` config entries' remote URLs name, lowercased.
    static func host(fromConfig output: String) -> String? {
        var hosts: Set<String> = []
        for entry in output.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            // A rewrite may point a remote somewhere its URL does not say.
            guard parts[0].hasPrefix("remote."), let host = remoteHost(parts[1]) else { return nil }
            hosts.insert(host)
        }
        return hosts.count == 1 ? hosts.first : nil
    }

    private static func remoteHost(_ url: String) -> String? {
        guard let webURL = GitService.webURLFromRemoteURL(url),
              let components = URLComponents(string: webURL), let name = components.host?.lowercased(),
              name.contains("."), name.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        else { return nil }
        // An https remote's port is the web host's; an SSH one's is not.
        let isWeb = url.hasPrefix("https://") || url.hasPrefix("http://")
        return isWeb ? components.port.map { "\(name):\($0)" } ?? name : name
    }
}
