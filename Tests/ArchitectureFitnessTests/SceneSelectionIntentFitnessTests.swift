import Foundation
import Testing

/// The scene's selection has one writer, `SceneSelectionModel`, and every
/// transition there carries its own result. A SwiftUI `onChange` reaction that
/// reads the selection and writes it back has to guess which intent produced the
/// change, runs after the writer has finished, and clobbers any entry point it
/// did not anticipate. That was the cause of the launch composer and the
/// sidebar's new-task icon both landing on a workspace's home.
@Suite("Scene selection intent fitness")
struct SceneSelectionIntentFitnessTests {
    @Test("The workspace-change reaction does not write the scene selection back")
    func theWorkspaceChangeReactionDoesNotRewriteTheSelection() throws {
        let source = try String(contentsOf: contentView(), encoding: .utf8)
        let body = try #require(functionBody(named: "handleSelectedWorkspaceChanged", in: source))

        for forbidden in ["sceneSelection.openWorkspace(", "consumeComposerRetarget", "isComposingTask,"] {
            #expect(
                !body.contains(forbidden),
                """
                handleSelectedWorkspaceChanged reacts to a selection change, so it must not decide \
                the selection again with `\(forbidden)`. Put the rule in SceneSelectionModel, where \
                the transition is explicit.
                """
            )
        }
    }

    @Test("No retarget token is carried between the scene selection model and its observers")
    func noRetargetTokenSurvives() throws {
        let root = repositoryRoot().appendingPathComponent("Astra")
        var offenders: [String] = []
        for file in try swiftFiles(under: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("consumeComposerRetarget") || source.contains("retargetedComposerWorkspaceID") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "A token for the observer to read back is the guess this rule removed: \(offenders.sorted())")
    }

    @Test("The matcher finds a function body and ignores a different function")
    func theMatcherFindsABody() throws {
        let source = """
        func other() { sceneSelection.openWorkspace(nil) }
        private func target() {
            if a { b() }
            c()
        }
        """
        let body = try #require(functionBody(named: "target", in: source))
        #expect(body.contains("c()"))
        #expect(!body.contains("openWorkspace"))
    }

    // MARK: - Helpers

    private func contentView() -> URL {
        repositoryRoot().appendingPathComponent("Astra/Views/ContentView.swift")
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("Astra").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}
