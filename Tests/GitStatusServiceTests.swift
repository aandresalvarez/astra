import Testing
@testable import ASTRA
import ASTRAGitContracts

@Suite("Git Status Service")
struct GitStatusServiceTests {
    @Test("status service reads porcelain-z through injected runner")
    func statusServiceReadsPorcelainZThroughInjectedRunner() async {
        let probe = GitStatusServiceRunnerProbe(outputs: [
            "--no-optional-locks status --porcelain=v1 -z": "M  Sources/App.swift\0?? Notes.md\0"
        ])
        let service = GitStatusService { repoPath, arguments in
            await probe.run(repoPath: repoPath, arguments: arguments)
        }

        let files = await service.getStatusFiles(at: "/repo")

        #expect(files == [
            GitStatusFile(relativePath: "Sources/App.swift", status: "M", isStaged: true),
            GitStatusFile(relativePath: "Notes.md", status: "?", isStaged: false)
        ])
        #expect(await probe.calls == [
            GitStatusServiceRunnerProbe.Call(
                repoPath: "/repo",
                arguments: ["--no-optional-locks", "status", "--porcelain=v1", "-z"]
            )
        ])
    }

    @Test("diff stats combine unstaged and staged numstat output without subprocesses")
    func diffStatsCombineUnstagedAndStagedNumstatOutput() async {
        let probe = GitStatusServiceRunnerProbe(outputs: [
            "--no-optional-locks diff --numstat": "2\t1\tA.swift\n-\t-\tBinary.dat",
            "--no-optional-locks diff --cached --numstat": "3\t4\tB.swift"
        ])
        let service = GitStatusService { repoPath, arguments in
            await probe.run(repoPath: repoPath, arguments: arguments)
        }

        let stats = await service.getDiffStats(at: "/repo")

        #expect(stats.additions == 5)
        #expect(stats.deletions == 5)
        #expect(await probe.calls.map(\.arguments) == [
            ["--no-optional-locks", "diff", "--numstat"],
            ["--no-optional-locks", "diff", "--cached", "--numstat"]
        ])
    }

    @Test("numstat parsing ignores binary and malformed rows")
    func numstatParsingIgnoresBinaryAndMalformedRows() {
        let stats = GitStatusService.parseNumstat(
            unstaged: "10\t2\tA.swift\n-\t-\tImage.png\nbad row",
            staged: "4 5 B.swift\n1\t0\tC.swift"
        )

        #expect(stats.additions == 15)
        #expect(stats.deletions == 7)
    }

    @Test("staged diff truncates through the status boundary")
    func stagedDiffTruncatesThroughStatusBoundary() async {
        let probe = GitStatusServiceRunnerProbe(outputs: [
            "--no-optional-locks diff --cached": String(repeating: "abc", count: 50)
        ])
        let service = GitStatusService { repoPath, arguments in
            await probe.run(repoPath: repoPath, arguments: arguments)
        }

        let diff = await service.getStagedDiff(at: "/repo", limit: 20)

        #expect(diff.hasSuffix("...[truncated]"))
        #expect(diff.utf8.count <= 40)
    }
}

private actor GitStatusServiceRunnerProbe {
    struct Call: Equatable {
        let repoPath: String
        let arguments: [String]
    }

    private let outputs: [String: String]
    private var recordedCalls: [Call] = []

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    var calls: [Call] {
        recordedCalls
    }

    func run(repoPath: String, arguments: [String]) -> String {
        recordedCalls.append(Call(repoPath: repoPath, arguments: arguments))
        return outputs[arguments.joined(separator: " ")] ?? ""
    }
}
