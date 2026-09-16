import Foundation
import Testing

/// Guards the one SwiftUI shape that can wedge the app rather than merely slow
/// it: a value measured during layout being written back into the state that
/// drives layout.
@Suite("View state feedback fitness")
struct ViewStateFeedbackFitnessTests {
    /// A `GeometryReader` preference is measured *during* layout, so writing one
    /// straight into `@State` invalidates the body that published it, which
    /// re-measures and publishes again. That edge only terminates if the
    /// re-measured value happens to come back identical. Production hit the
    /// non-terminating case: an app was recovered at 100% of one core with 1,925
    /// of 1,937 main-thread samples inside a single non-returning
    /// `GraphHost.flushTransactions`, with the sidebar's row-frame preference
    /// `reduce` on the stack.
    ///
    /// Two shapes are safe and both are in use. When the value is never a layout
    /// input, hold it in a reference box — `WorkspaceSidebarAnchorTracker`,
    /// `KanbanDropGeometry` — so the write cannot invalidate at all; those
    /// assignments are dotted (`box.field = value`) and this test ignores them.
    /// When it *is* a layout input, quantize it to the decision the body
    /// actually reads and write only when that decision flips, as the right
    /// rail's scroll shadows and `updateChatBottomState` do. This test guards
    /// the second shape, and the first is what makes it satisfiable.
    @Test("Preference sinks never write view state unconditionally")
    func preferenceSinksNeverWriteViewStateUnconditionally() throws {
        let root = repositoryRoot().appendingPathComponent("Astra")
        var violations: [String] = []

        for file in try swiftFiles(under: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(".onPreferenceChange(") else { continue }
            let stateProperties = declaredStateProperties(in: source)

            for body in preferenceSinkBodies(in: source) {
                for name in stateProperties where assignsWithoutChangeGuard(name, in: body) {
                    violations.append("\(file.lastPathComponent): \(name)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            These `@State` properties are assigned inside an `onPreferenceChange` sink with
            nothing comparing them first. Hold the value in a `@MainActor final class` kept in
            `@State` if the body never reads it during layout, or compare before writing if it
            does: \(violations.sorted())
            """
        )
    }

    /// The scan is text-based, so it is only worth what it catches. Rebuild each
    /// fixed site's original defect here: if a future refactor of the matcher
    /// stops recognising one of these, the guard above has gone quiet without
    /// failing, and a silent fitness test is worse than none.
    @Test("The scan recognises every shape it was written to catch")
    func theScanRecognisesEveryShapeItWasWrittenToCatch() {
        let sidebar = "@State private var selectedWorkspaceRowFrame: CGRect?"
        #expect(declaredStateProperties(in: sidebar) == ["selectedWorkspaceRowFrame"])
        #expect(assignsWithoutChangeGuard("selectedWorkspaceRowFrame", in: """
            selectedWorkspaceRowFrame = frame
            """))
        // The Kanban board: three dictionaries of per-card frames.
        #expect(assignsWithoutChangeGuard("taskFrames", in: "taskFrames = frames"))
        // The right rail: continuous scroll metrics behind two booleans.
        #expect(assignsWithoutChangeGuard("scrollMetrics", in: "scrollMetrics = metrics"))

        // …and the shapes that replaced them must stay clean. A write through a
        // reference box does not invalidate, so the dotted form is allowed even
        // though `dropGeometry` is itself `@State`.
        #expect(!assignsWithoutChangeGuard("dropGeometry", in: "dropGeometry.taskFrames = frames"))
        #expect(!assignsWithoutChangeGuard("anchorTracker", in: "anchorTracker.selectedRowFrame = frame"))
        #expect(!assignsWithoutChangeGuard("showsTopRailScrollShadow", in: """
            if showsTopRailScrollShadow != metrics.showsTopShadow {
                showsTopRailScrollShadow = metrics.showsTopShadow
            }
            """))
        // A prefix of another property name is not that property.
        #expect(!assignsWithoutChangeGuard("isChatAtBottom", in: "isChatAtBottomPinned = true"))
    }

    /// Closure-body extraction must not run past its own sink. A commented-out
    /// brace inside a sink would otherwise swallow the rest of the file and
    /// attribute a neighbouring assignment to the preference.
    @Test("Sink extraction stops at its own closing brace")
    func sinkExtractionStopsAtItsOwnClosingBrace() {
        let source = """
            .onPreferenceChange(FrameKey.self) { frame in
                // was: if frame != stored { stored = frame }
                box.frame = frame
            }
            .onAppear { unrelated = 0 }
            """
        let bodies = preferenceSinkBodies(in: source)
        #expect(bodies.count == 1)
        #expect(bodies.first?.contains("box.frame = frame") == true)
        #expect(bodies.first?.contains("unrelated") == false)
    }

    // MARK: - Scanning

    private func declaredStateProperties(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@State"), let keyword = trimmed.range(of: " var ") else { return nil }
            let name = trimmed[keyword.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
    }

    /// Body of every `.onPreferenceChange(…) { … }` closure, delimited by brace
    /// depth. Braces in line comments and string literals are skipped.
    private func preferenceSinkBodies(in source: String) -> [String] {
        var bodies: [String] = []
        var searchStart = source.startIndex

        while let call = source.range(of: ".onPreferenceChange(", range: searchStart..<source.endIndex) {
            searchStart = call.upperBound
            guard let open = source[call.upperBound...].firstIndex(of: "{") else { continue }

            var depth = 0
            var index = open
            var inString = false
            var closed: String.Index?
            while index < source.endIndex {
                let character = source[index]
                let next = source.index(after: index)
                if inString {
                    if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "/", next < source.endIndex, source[next] == "/" {
                    while index < source.endIndex, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                    continue
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        closed = index
                        break
                    }
                }
                index = next
            }

            guard let end = closed else { continue }
            bodies.append(String(source[source.index(after: open)..<end]))
            searchStart = end
        }

        return bodies
    }

    /// True when `name` is assigned at statement position somewhere in `body`
    /// and nothing in the same closure compares it. A dotted write such as
    /// `box.field = value` does not match: the receiver is a reference, so the
    /// assignment never invalidates the view.
    private func assignsWithoutChangeGuard(_ name: String, in body: String) -> Bool {
        let lines = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let assigns = lines.contains { line in
            guard !line.hasPrefix("//"), line.hasPrefix(name) else { return false }
            let rest = line.dropFirst(name.count).drop { $0 == " " }
            return rest.hasPrefix("=") && !rest.hasPrefix("==")
        }
        guard assigns else { return false }

        return !lines.contains { $0.contains(name) && ($0.contains("!=") || $0.contains("==")) }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }
}
