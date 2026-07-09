import Foundation
import Testing
@testable import ASTRA

/// Regression coverage for a HIGH-severity release-pipeline finding: the
/// release BUILD number (CFBundleVersion, which Sparkle compares globally
/// across ALL versions to decide whether an update is available) used to be
/// derived from a raw COUNT of existing `vX.Y.Z` git tags in
/// `.github/workflows/release.yml`'s "Determine release version and build"
/// step, mirrored by `default_app_build()` in `script/build_and_run.sh`.
///
/// That scheme was not append-only: deleting an already-published version's
/// tag (which does NOT delete its GitHub Release / already-shipped
/// CFBundleVersion) shifted the count down for every release after it, so an
/// ordinary next release could recompute a build number that collides with a
/// still-published, still-installed release's CFBundleVersion -- silently
/// corrupting Sparkle's update detection for users on the collided build. A
/// `workflow_dispatch` re-run targeting an older, already-tagged, non-latest
/// version had the identical failure mode: it recomputed the CURRENT total
/// tag count, not the count at that version's original publish time.
///
/// The fix derives BUILD purely from the version string's own
/// (MAJOR, MINOR, PATCH) components -- `MAJOR*1_000_000 + MINOR*10_000 +
/// PATCH` -- with no git tag enumeration at all, in both files. These tests
/// extract the ACTUAL shipped logic (the function body / workflow step body,
/// read fresh from disk) and execute it against disposable temp git repos, so
/// they fail if the real files regress back toward counting/ranking tags.
@Suite("Release Build Number Derivation")
struct ReleaseBuildNumberDerivationTests {

    // MARK: - Process / fixture helpers

    private func runShell(
        _ command: String,
        in directory: String,
        extraEnvironment: [String: String] = [:]
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-eo", "pipefail", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func makeTempDir(_ label: String) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-build-num-\(label)-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A throwaway repo with an initial commit and a `vX.Y.Z` tag on it for
    /// every patch in `1...highestPatch`, skipping any patch numbers in
    /// `excluding` (so a test can start from a repo that already has "gaps"
    /// the way the real repo does, or simulate deleting a tag after the
    /// fact via a follow-up `git tag -d`).
    private func makeTempRepoWithTags(minor: Int = 1, patches: [Int]) throws -> String {
        let path = try makeTempDir("repo")
        let initResult = runShell(
            "git init -q -b main && git -c commit.gpgsign=false -c user.name='T' -c user.email='t@example.invalid' commit -q --allow-empty -m init",
            in: path
        )
        #expect(initResult.exitCode == 0, "git init failed: \(initResult.output)")
        for patch in patches {
            let tagResult = runShell("git tag v0.\(minor).\(patch)", in: path)
            #expect(tagResult.exitCode == 0, "git tag failed: \(tagResult.output)")
        }
        return path
    }

    // MARK: - Source extraction (reads the ACTUAL shipped scripts, not a reimplementation)

    /// Extracts a top-level `name() { ... }` bash function body verbatim
    /// from a script's source text, keyed off the literal opening line and a
    /// matching `}` back at column 0.
    private func extractFunction(named name: String, from source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(name)() {") }) else {
            throw TestFailure("could not find `\(name)() {` in source")
        }
        guard let end = lines[start...].firstIndex(where: { $0 == "}" }) else {
            throw TestFailure("could not find closing brace for `\(name)`")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// Extracts the body of release.yml's "Determine release version and
    /// build" `run: |` block (between `id: version` and the next top-level
    /// job key), dedented to plain shell. Located by content, not fixed line
    /// numbers, so it keeps working as the surrounding workflow evolves.
    private func extractVersionStepScript(from workflow: String) throws -> String {
        let lines = workflow.components(separatedBy: "\n")
        guard let idLine = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "id: version" }) else {
            throw TestFailure("could not find `id: version` marker in release.yml")
        }
        guard let runLine = lines[idLine...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "run: |" }) else {
            throw TestFailure("could not find `run: |` after `id: version` in release.yml")
        }

        var bodyLines: [String] = []
        var dedent: Int?
        var index = runLine + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let leading = line.prefix(while: { $0 == " " }).count
            if trimmed.isEmpty {
                bodyLines.append("")
                index += 1
                continue
            }
            if let dedent, leading < dedent {
                break
            }
            if dedent == nil {
                dedent = leading
            }
            bodyLines.append(String(line.dropFirst(dedent ?? 0)))
            index += 1
        }
        guard dedent != nil else {
            throw TestFailure("run block after `id: version` was empty")
        }
        return bodyLines.joined(separator: "\n")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Runs the real `.github/workflows/release.yml` version/build
    /// derivation logic (extracted fresh from disk) inside `repoPath`,
    /// exactly as GitHub Actions would invoke a `run: |` step (bash, `-e`,
    /// `pipefail`), and returns the parsed `$GITHUB_OUTPUT` key/value pairs.
    /// Always uses the `workflow_dispatch` event so the push-only guards
    /// (which shell out to `gh` / GitHub's API) never run -- this is a pure,
    /// network-free exercise of the build-number formula, which does not
    /// itself branch on event name.
    private func runVersionStep(
        version: String,
        build: String = "",
        in repoPath: String
    ) throws -> [String: String] {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let script = try extractVersionStepScript(from: workflow)
        let scriptPath = URL(fileURLWithPath: repoPath).appendingPathComponent(".version-step-under-test.sh").path
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let outputPath = URL(fileURLWithPath: repoPath).appendingPathComponent(".github-output-under-test").path
        FileManager.default.createFile(atPath: outputPath, contents: nil)

        let result = runShell(
            "bash \(scriptPath)",
            in: repoPath,
            extraEnvironment: [
                "INPUT_VERSION": version,
                "INPUT_BUILD": build,
                "GH_TOKEN": "",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REF_NAME": "",
                "GITHUB_OUTPUT": outputPath
            ]
        )
        #expect(result.exitCode == 0, "version step failed for version=\(version): \(result.output)")

        let outputContents = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
        var parsed: [String: String] = [:]
        for line in outputContents.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            parsed[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return parsed
    }

    /// Runs the real `default_app_build()` from `script/build_and_run.sh`
    /// (extracted fresh from disk) against a bare version string.
    private func runDefaultAppBuild(version: String) throws -> (exitCode: Int32, output: String) {
        let scriptSource = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let function = try extractFunction(named: "default_app_build", from: scriptSource)
        let tempDir = try makeTempDir("dab")
        return runShell(
            "#!/usr/bin/env bash\n\(function)\ndefault_app_build \(version)",
            in: tempDir
        )
    }

    // MARK: - script/build_and_run.sh: default_app_build()

    @Test("default_app_build() is a pure function of the version string, not of git tag state")
    func defaultAppBuildIsPureFunctionOfVersion() throws {
        let scriptSource = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let function = try extractFunction(named: "default_app_build", from: scriptSource)

        // The whole point of the fix: this function must not shell out to
        // git or otherwise inspect tag history at all.
        #expect(!function.contains("git "))
        #expect(!function.contains("wc -l"))
        #expect(function.contains("1000000"))
        #expect(function.contains("10000"))

        let cases: [(String, String)] = [
            ("0.1.27", "10027"),
            ("0.1.28", "10028"),
            ("0.1.30", "10030"),
            ("0.2.0", "20000"),
            ("1.0.0", "1000000"),
            ("0.01.08", "10008") // leading zeros must not be parsed as octal
        ]
        for (version, expected) in cases {
            let result = try runDefaultAppBuild(version: version)
            #expect(result.exitCode == 0, "default_app_build(\(version)) failed: \(result.output)")
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected, "default_app_build(\(version)) == \(result.output), expected \(expected)")
        }
    }

    @Test("default_app_build() rejects a malformed version instead of guessing")
    func defaultAppBuildRejectsMalformedVersion() throws {
        let result = try runDefaultAppBuild(version: "not-a-version")
        #expect(result.exitCode != 0)
    }

    @Test("build_and_run.sh passes the resolved APP_VERSION into default_app_build(), keeping the two coupled")
    func buildAndRunPassesVersionIntoDefaultAppBuild() throws {
        let scriptSource = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        #expect(scriptSource.contains(#"APP_BUILD="${ASTRA_BUILD:-$(default_app_build "$APP_VERSION")}""#))
    }

    // MARK: - release.yml: "Determine release version and build"

    @Test("release.yml no longer derives the build number from a git tag count")
    func releaseWorkflowNoLongerCountsTags() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let script = try extractVersionStepScript(from: workflow)

        #expect(!script.contains("EXISTING_TAG_COUNT"))
        #expect(!script.contains("wc -l"))
        #expect(script.contains("VERSION_MAJOR"))
        #expect(script.contains("VERSION_MINOR"))
        #expect(script.contains("VERSION_PATCH"))
        #expect(script.contains("1000000"))
    }

    @Test("the same version always produces the same build number, regardless of tag history")
    func sameVersionAlwaysProducesSameBuild() throws {
        let repoPath = try makeTempRepoWithTags(patches: Array(1...30))

        let before = try runVersionStep(version: "0.1.20", in: repoPath)
        #expect(before["build"] == "10020")

        // Delete a handful of tags both before and after v0.1.20, and add a
        // brand new one past the current highest -- none of this may move
        // the build number for v0.1.20, since it no longer depends on tag
        // history at all.
        for patch in [5, 10, 22, 27] {
            let deleteResult = runShell("git tag -d v0.1.\(patch)", in: repoPath)
            #expect(deleteResult.exitCode == 0)
        }
        let addResult = runShell("git tag v0.1.31", in: repoPath)
        #expect(addResult.exitCode == 0)

        let after = try runVersionStep(version: "0.1.20", in: repoPath)
        #expect(after["build"] == "10020")
        #expect(after["build"] == before["build"])
    }

    @Test("deleting an already-published version's tag does not change the build number of a later, not-yet-tagged release")
    func tagDeletionDoesNotShiftLaterBuildNumbers() throws {
        // Reproduces the audit's concrete failure scenario: v0.1.1..v0.1.30
        // are tagged and published (so old-scheme EXISTING_TAG_COUNT == 30).
        let repoPath = try makeTempRepoWithTags(patches: Array(1...30))

        let latestBefore = try runVersionStep(version: "0.1.31", in: repoPath)
        // 0.1.30 is "already published"; simulate deriving its build the
        // way a workflow_dispatch repair run would, before any deletion.
        let publishedBefore = try runVersionStep(version: "0.1.30", in: repoPath)

        // Someone deletes the tag for an already-published version. This
        // does NOT delete the GitHub Release / already-shipped
        // CFBundleVersion=10015 for v0.1.15 -- it is still installed on
        // users' machines.
        let deleteResult = runShell("git tag -d v0.1.15", in: repoPath)
        #expect(deleteResult.exitCode == 0)

        // The next ordinary release, v0.1.31, is tagged (fetch-tags:true
        // means the just-pushed tag is already local by the time this step
        // runs in the real workflow).
        let addResult = runShell("git tag v0.1.31", in: repoPath)
        #expect(addResult.exitCode == 0)

        let latestAfter = try runVersionStep(version: "0.1.31", in: repoPath)
        let publishedAfter = try runVersionStep(version: "0.1.30", in: repoPath)

        // The old raw-count scheme would have computed EXISTING_TAG_COUNT ==
        // 30 here (29 remaining old tags + the new v0.1.31 tag) and produced
        // DEFAULT_BUILD=30 -- an exact collision with v0.1.30's build=30.
        // The fixed formula must be completely unaffected by the deletion.
        #expect(latestAfter["build"] == latestBefore["build"])
        #expect(publishedAfter["build"] == publishedBefore["build"])
        #expect(latestAfter["build"] == "10031")
        #expect(publishedAfter["build"] == "10030")

        // The core assertion: no collision between the two distinct,
        // still-installed-somewhere versions.
        #expect(latestAfter["build"] != publishedAfter["build"])
    }

    @Test("a workflow_dispatch re-run of an older, already-tagged version stays stable as newer tags are added")
    func nonLatestVersionRepairStaysStableAsNewerTagsAppear() throws {
        // The MEDIUM finding: repairing/republishing an old version must not
        // recompute from "how many tags exist right now" -- that would drift
        // every time a newer release is tagged in between.
        let repoPath = try makeTempRepoWithTags(patches: Array(1...20))

        let repairBefore = try runVersionStep(version: "0.1.10", in: repoPath)
        #expect(repairBefore["build"] == "10010")

        for patch in 21...35 {
            let tagResult = runShell("git tag v0.1.\(patch)", in: repoPath)
            #expect(tagResult.exitCode == 0)
        }

        let repairAfter = try runVersionStep(version: "0.1.10", in: repoPath)
        #expect(repairAfter["build"] == repairBefore["build"])
        #expect(repairAfter["build"] == "10010")
    }

    @Test("build numbers strictly increase across a realistic version sequence")
    func buildNumbersStrictlyIncreaseAcrossVersionSequence() throws {
        let repoPath = try makeTempRepoWithTags(patches: Array(1...28))

        let sequence = ["0.1.27", "0.1.28", "0.1.29", "0.1.30", "0.2.0", "1.0.0"]
        var previousBuild: Int?
        for version in sequence {
            let outputs = try runVersionStep(version: version, in: repoPath)
            let build = try #require(outputs["build"].flatMap { Int($0) })
            if let previousBuild {
                #expect(build > previousBuild, "\(version) (build \(build)) must be > previous build \(previousBuild)")
            }
            previousBuild = build
        }
    }

    @Test("v0.1.28's new build number is strictly greater than v0.1.27's old raw-count build (27), no regression vs the live in-flight release")
    func v0128DoesNotRegressBelowV0127sOldBuildNumber() throws {
        let repoPath = try makeTempRepoWithTags(patches: Array(1...27))
        let outputs = try runVersionStep(version: "0.1.28", in: repoPath)
        let build = try #require(outputs["build"].flatMap { Int($0) })
        #expect(build > 27, "v0.1.28 must build higher than the already-published v0.1.27 (old scheme build=27); got \(build)")
    }

    @Test("an explicit INPUT_BUILD override still wins over the computed default")
    func explicitBuildOverrideStillWins() throws {
        let repoPath = try makeTempRepoWithTags(patches: Array(1...5))
        let outputs = try runVersionStep(version: "0.1.6", build: "424242", in: repoPath)
        #expect(outputs["build"] == "424242")
    }

    @Test("an invalid INPUT_BUILD override is rejected rather than silently falling back")
    func invalidBuildOverrideIsRejected() throws {
        let repoPath = try makeTempRepoWithTags(patches: [1])
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let script = try extractVersionStepScript(from: workflow)
        let scriptPath = URL(fileURLWithPath: repoPath).appendingPathComponent(".version-step-under-test.sh").path
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let outputPath = URL(fileURLWithPath: repoPath).appendingPathComponent(".github-output-under-test").path
        FileManager.default.createFile(atPath: outputPath, contents: nil)

        let result = runShell(
            "bash \(scriptPath)",
            in: repoPath,
            extraEnvironment: [
                "INPUT_VERSION": "0.1.2",
                "INPUT_BUILD": "not-a-number",
                "GH_TOKEN": "",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REF_NAME": "",
                "GITHUB_OUTPUT": outputPath
            ]
        )
        #expect(result.exitCode != 0)
    }
}
