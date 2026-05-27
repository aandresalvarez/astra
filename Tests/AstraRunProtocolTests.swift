import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeProtocolTestContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Astra Run Protocol")
struct AstraRunProtocolTests {
    @Test("Valid todo.replace marker parses and normalizes")
    func validTodoReplaceParses() throws {
        let line = #"ASTRA_EVENT {"v":1,"type":"todo.replace","items":[{"text":"Inspect parser","status":"pending"},{"text":"Run tests","status":"done"}]}"#

        let parsed = try #require(AstraRunProtocolParser.parseMarkerLine(line))
        guard case .valid(.todoReplace(let items)) = parsed else {
            Issue.record("Expected valid todo.replace, got \(parsed)")
            return
        }

        #expect(items.map(\.text) == ["Inspect parser", "Run tests"])
        #expect(items.map(\.status) == [.pending, .done])
        #expect(parsed.taskEventType == "astra.todo.replace")
        #expect(parsed.normalizedPayload.contains(#""type":"todo.replace""#))
    }

    @Test("Valid complete marker parses and normalizes")
    func validCompleteParses() throws {
        let line = #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Implemented protocol storage.","verifiedBy":"swift test"}"#

        let parsed = try #require(AstraRunProtocolParser.parseMarkerLine(line))
        guard case .valid(.complete(let summary, let verifiedBy)) = parsed else {
            Issue.record("Expected valid complete, got \(parsed)")
            return
        }

        #expect(summary == "Implemented protocol storage.")
        #expect(verifiedBy == "swift test")
        #expect(parsed.taskEventType == "astra.complete")
    }

    @Test("Valid plan step marker parses and normalizes")
    func validPlanStepMarkerParses() throws {
        let line = #"ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","stepID":"step-1","summary":"Verified output"}"#

        let parsed = try #require(AstraRunProtocolParser.parseMarkerLine(line))
        guard case .valid(.planStep(let progress)) = parsed else {
            Issue.record("Expected valid plan step, got \(parsed)")
            return
        }

        #expect(progress.type == "plan.step.completed")
        #expect(progress.planID == "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")
        #expect(progress.stepID == "step-1")
        #expect(progress.status == .done)
        #expect(progress.summary == "Verified output")
        #expect(parsed.taskEventType == "plan.step.completed")
        #expect(parsed.normalizedPayload.contains(#""type":"plan.step.completed""#))
    }

    @Test("Unknown version, unknown type, and malformed JSON become invalid events")
    func invalidMarkersParse() throws {
        let unsupportedVersion = try #require(AstraRunProtocolParser.parseMarkerLine(#"ASTRA_EVENT {"v":2,"type":"complete","summary":"done"}"#))
        let unsupportedType = try #require(AstraRunProtocolParser.parseMarkerLine(#"ASTRA_EVENT {"v":1,"type":"artifact","path":"x"}"#))
        let malformed = try #require(AstraRunProtocolParser.parseMarkerLine(#"ASTRA_EVENT {"v":1,"type":"complete""#))

        guard case .invalid(let versionReason) = unsupportedVersion else {
            Issue.record("Expected invalid version")
            return
        }
        guard case .invalid(let typeReason) = unsupportedType else {
            Issue.record("Expected invalid type")
            return
        }
        guard case .invalid(let malformedReason) = malformed else {
            Issue.record("Expected malformed JSON")
            return
        }

        #expect(versionReason == "unsupported version")
        #expect(typeReason == "unsupported type")
        #expect(malformedReason == "malformed JSON")
    }

    @Test("Non-marker lines are ignored by the parser")
    func nonMarkerIgnored() {
        #expect(AstraRunProtocolParser.parseMarkerLine(" ASTRA_EVENT {\"v\":1}") == nil)
        #expect(AstraRunProtocolParser.parseMarkerLine("ASTRA_EVENT{\"v\":1}") == nil)
        #expect(AstraRunProtocolParser.parseMarkerLine("normal text") == nil)
    }

    @Test("Filter strips marker lines and preserves surrounding text")
    func filterStripsMarkers() {
        var filter = AstraRunProtocolTextFilter()
        let marker = #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Done.","verifiedBy":"unit tests"}"#
        let result = filter.process(text: "Before\n\(marker)\nAfter")

        #expect(result.outputs.count == 3)
        #expect(result.outputs[0] == .text("Before\n"))
        guard case .protocolEvent(.valid(.complete(let summary, _))) = result.outputs[1] else {
            Issue.record("Expected protocol completion")
            return
        }
        #expect(summary == "Done.")
        #expect(result.outputs[2] == .text("After"))
    }

    @Test("Filter strips markdown-bulleted marker lines")
    func filterStripsBulletedMarkers() {
        var filter = AstraRunProtocolTextFilter()
        let marker = #"• ASTRA_EVENT {"v":1,"type":"plan.step.started","planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","stepID":"research","status":"running"}"#
        let result = filter.process(text: "Visible\n\(marker)\n")

        #expect(result.outputs.count == 2)
        #expect(result.outputs[0] == .text("Visible\n"))
        guard case .protocolEvent(.valid(.planStep(let progress))) = result.outputs[1] else {
            Issue.record("Expected plan.step marker")
            return
        }
        #expect(progress.stepID == "research")
        #expect(progress.status == .running)
    }

    @Test("Filter strips heavy-bulleted hard-wrapped plan markers")
    func filterStripsHardWrappedPlanMarkers() {
        var filter = AstraRunProtocolTextFilter()
        let text = """
        ● I'll build a clean page.
        ● ASTRA_EVENT {"v":1,"type":"plan.step.started","planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","s
           tepID":"step-1","status":"running"}
        ✓ Create index.html (+124)
        ● ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87",
           "stepID":"step-1","status":"done","summary":"Created index.html"}
        Done.
        """

        let result = filter.process(text: text)
        let visible = result.outputs.compactMap { output -> String? in
            guard case .text(let text) = output else { return nil }
            return text
        }.joined()
        let planEvents = result.outputs.compactMap { output -> AstraRunProtocolEvent.PlanStepProgress? in
            guard case .protocolEvent(.valid(.planStep(let progress))) = output else { return nil }
            return progress
        }

        #expect(!visible.contains("ASTRA_EVENT"))
        #expect(!visible.contains("tepID"))
        #expect(visible.contains("I'll build a clean page."))
        #expect(visible.contains("Create index.html"))
        #expect(visible.contains("Done."))
        #expect(planEvents.map(\.type) == ["plan.step.started", "plan.step.completed"])
        #expect(planEvents.map(\.stepID) == ["step-1", "step-1"])
    }

    @Test("Filter strips hard-wrapped completion marker continuations")
    func filterStripsHardWrappedCompletionMarkerContinuations() {
        var filter = AstraRunProtocolTextFilter()
        let text = """
        ● ASTRA_EVENT {"v":1,"type":"complete","summary":"Created index.html and styles.css
           with placeholder content that wrapped before the closing quote
           and still belongs to the summary.","verifiedBy":"File system verification"}
        Visible final response.
        """

        let result = filter.process(text: text)
        let visible = result.outputs.compactMap { output -> String? in
            guard case .text(let text) = output else { return nil }
            return text
        }.joined()

        #expect(!visible.contains("ASTRA_EVENT"))
        #expect(!visible.contains("verifiedBy"))
        #expect(!visible.contains("wrapped before the closing quote"))
        #expect(visible.contains("Visible final response."))
        guard case .protocolEvent(.valid(.complete(let summary, let verifiedBy))) = result.outputs.first else {
            Issue.record("Expected completion protocol marker")
            return
        }
        #expect(summary.contains("wrapped before the closing quote"))
        #expect(verifiedBy == "File system verification")
    }

    @Test("Filter strips invalid marker lines")
    func filterStripsInvalidMarkers() {
        var filter = AstraRunProtocolTextFilter()
        let result = filter.process(text: "A\nASTRA_EVENT {bad json}\nB")

        #expect(result.outputs.count == 3)
        #expect(result.outputs[0] == .text("A\n"))
        guard case .protocolEvent(.invalid(let reason)) = result.outputs[1] else {
            Issue.record("Expected invalid protocol event")
            return
        }
        #expect(reason == "malformed JSON")
        #expect(result.outputs[2] == .text("B"))
    }

    @Test("Display sanitizer hides persisted orphan protocol fragments")
    func displaySanitizerHidesPersistedOrphanProtocolFragments() {
        let text = """
        ● I'll build a clean page.
           tepID":"step-1","status":"running"}
        ✓ Create .astra/tasks/3BAB3C9D/index.html (+124)
        ● ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
           "stepID":"step-1","status":"done","summary":"Created index.html with semantic sections"}
           tepID":"step-2","status":"running"}
        ✓ Create .astra/tasks/3BAB3C9D/styles.css (+326)
        ● ASTRA_EVENT {"v":1,"type":"complete","summary":"Verified both files created successfully
           with index.html and styles.css in black and white design. All placeholder content is clearly
           marked for customization.","verifiedBy":"File system verification"}
        Final response.
        """

        let cleaned = AstraRunProtocolDisplaySanitizer.clean(text)

        #expect(!cleaned.contains("ASTRA_EVENT"))
        #expect(!cleaned.contains("tepID"))
        #expect(!cleaned.contains("\"stepID\""))
        #expect(!cleaned.contains("verifiedBy"))
        #expect(!cleaned.contains("marked for customization"))
        #expect(cleaned.contains("I'll build a clean page."))
        #expect(cleaned.contains("Create .astra/tasks/3BAB3C9D/index.html"))
        #expect(cleaned.contains("Create .astra/tasks/3BAB3C9D/styles.css"))
        #expect(cleaned.contains("Final response."))
    }

    @Test("Filter reassembles split marker chunks before parsing")
    func filterReassemblesSplitMarkers() {
        var filter = AstraRunProtocolTextFilter()
        let first = filter.process(text: "ASTRA")
        let second = filter.process(text: #"_EVENT {"v":1,"type":"todo.replace","items":[{"text":"One","status":"pending"}]}"# + "\nVisible")

        #expect(first.outputs.isEmpty)
        #expect(second.outputs.count == 2)
        guard case .protocolEvent(.valid(.todoReplace(let items))) = second.outputs[0] else {
            Issue.record("Expected todo protocol event")
            return
        }
        #expect(items.first?.text == "One")
        #expect(second.outputs[1] == .text("Visible"))
    }

    @Test("Filter flushes buffered non-marker text at run end")
    func filterFlushesBufferedText() {
        var filter = AstraRunProtocolTextFilter()
        let first = filter.process(text: "ASTRA")
        let flushed = filter.flush()

        #expect(first.outputs.isEmpty)
        #expect(flushed.outputs == [.text("ASTRA")])
    }

    @Test("Parser enforces V1 size limits")
    func parserEnforcesLimits() throws {
        let tooManyItems = (0...AstraRunProtocolLimits.maxTodoItems)
            .map { #"{"text":"Item \#($0)","status":"pending"}"# }
            .joined(separator: ",")
        let tooMany = try #require(AstraRunProtocolParser.parseMarkerLine(
            #"ASTRA_EVENT {"v":1,"type":"todo.replace","items":[\#(tooManyItems)]}"#
        ))
        let longItemText = String(repeating: "x", count: AstraRunProtocolLimits.maxTodoItemTextCharacters + 1)
        let longItem = try #require(AstraRunProtocolParser.parseMarkerLine(
            #"ASTRA_EVENT {"v":1,"type":"todo.replace","items":[{"text":"\#(longItemText)","status":"pending"}]}"#
        ))
        let longSummary = String(repeating: "x", count: AstraRunProtocolLimits.maxCompletionSummaryCharacters + 1)
        let summary = try #require(AstraRunProtocolParser.parseMarkerLine(
            #"ASTRA_EVENT {"v":1,"type":"complete","summary":"\#(longSummary)"}"#
        ))
        let longVerifiedBy = String(repeating: "x", count: AstraRunProtocolLimits.maxVerifiedByCharacters + 1)
        let verifiedBy = try #require(AstraRunProtocolParser.parseMarkerLine(
            #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Done","verifiedBy":"\#(longVerifiedBy)"}"#
        ))

        guard case .invalid(let tooManyReason) = tooMany,
              case .invalid(let longItemReason) = longItem,
              case .invalid(let summaryReason) = summary,
              case .invalid(let verifiedByReason) = verifiedBy else {
            Issue.record("Expected all over-limit markers to be invalid")
            return
        }

        #expect(tooManyReason == "too many todo items")
        #expect(longItemReason == "todo item too long")
        #expect(summaryReason == "completion summary too long")
        #expect(verifiedByReason == "verification summary too long")
    }

    @Test("Parser rejects oversized marker JSON")
    func parserRejectsOversizedJSON() throws {
        let padding = String(repeating: "x", count: AstraRunProtocolLimits.maxMarkerJSONBytes)
        let parsed = try #require(AstraRunProtocolParser.parseMarkerLine(
            #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Done","verifiedBy":"\#(padding)"}"#
        ))

        guard case .invalid(let reason) = parsed else {
            Issue.record("Expected oversized marker to be invalid")
            return
        }
        #expect(reason == "marker JSON too large")
    }

    @Test("Runtime pipeline filters parsed text through ARP")
    func pipelineFiltersParsedText() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        let marker = #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Finished.","verifiedBy":"unit tests"}"#
        let events = pipeline.process(ParsedEvent.text(text: "Before\n\(marker)\nAfter"))

        #expect(events.count == 3)
        guard case .text(let before) = events[0],
              case .astraProtocol(.valid(.complete(let summary, let verifiedBy))) = events[1],
              case .text(let after) = events[2] else {
            Issue.record("Expected text, protocol, text")
            return
        }

        #expect(before == "Before\n")
        #expect(summary == "Finished.")
        #expect(verifiedBy == "unit tests")
        #expect(after == "After")
    }

    @Test("Runtime pipeline leaves raw text untouched when ARP is unsupported")
    func pipelineFallsBackWhenUnsupported() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: false)
        let text = #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Finished."}"# + "\n"
        let events = pipeline.process(ParsedEvent.text(text: text))

        #expect(events.count == 1)
        guard case .text(let raw) = events.first else {
            Issue.record("Expected unsupported pipeline to pass through raw text")
            return
        }
        #expect(raw == text)
        #expect(pipeline.flushParsedEvents().isEmpty)
    }

    @Test("Runtime pipeline also filters generic agent text events")
    func pipelineFiltersAgentEvents() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        let text = #"ASTRA_EVENT {"v":1,"type":"todo.replace","items":[{"text":"Review","status":"pending"}]}"# + "\n"
        let events = pipeline.process(AgentEvent.text(text: text))

        #expect(events.count == 1)
        guard case .astraProtocol(.valid(.todoReplace(let items))) = events.first else {
            Issue.record("Expected agent protocol event")
            return
        }
        #expect(items.map(\.text) == ["Review"])
    }

    @Test("Runtime pipeline suppresses invalid marker spam after cap")
    func pipelineCapsInvalidMarkers() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        let invalidLines = Array(
            repeating: "ASTRA_EVENT {bad json}",
            count: AstraRunProtocolLimits.maxInvalidEventsPerRun + 3
        ).joined(separator: "\n") + "\n"

        let events = pipeline.process(ParsedEvent.text(text: invalidLines))
        let invalidCount = events.filter {
            if case .astraProtocol(.invalid) = $0 { return true }
            return false
        }.count

        #expect(invalidCount == AstraRunProtocolLimits.maxInvalidEventsPerRun)
        #expect(!events.contains {
            if case .text = $0 { return true }
            return false
        })
    }

    @Test("Runtime metadata advertises ARP support for promptable text runtimes")
    func runtimeMetadataAdvertisesARP() {
        #expect(AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: .claudeCode))
        #expect(AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: .copilotCLI))
        #expect(AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: .antigravityCLI))
        #expect(AgentRuntimeAdapterRegistry.descriptor(for: .claudeCode).supportsAstraRunProtocol)
        #expect(AgentRuntimeAdapterRegistry.descriptor(for: .copilotCLI).supportsAstraRunProtocol)
        #expect(AgentRuntimeAdapterRegistry.descriptor(for: .antigravityCLI).supportsAstraRunProtocol)
    }
}

@Suite("Astra Run Protocol Recording")
@MainActor
struct AstraRunProtocolRecordingTests {
    @Test("Recorder stores ARP event and leaves run output clean")
    func recorderStoresProtocolEvent() throws {
        let container = try makeProtocolTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let protocolEvent = AstraRunProtocolParsedEvent.valid(.complete(summary: "Finished implementation.", verifiedBy: "swift test"))
        AgentEventRecorder.recordClaudeRunEvent(.astraProtocol(protocolEvent), to: task, run: run, modelContext: context)
        AgentEventRecorder.recordClaudeRunEvent(.text(text: "Visible output"), to: task, run: run, modelContext: context)

        #expect(run.output == "Visible output")
        #expect(task.events.contains { $0.type == "astra.complete" })
        #expect(task.events.contains { $0.type == "agent.response" && $0.payload == "Visible output" })
    }

    @Test("Recorder applies plan step progress to current plan")
    func recorderAppliesPlanStepProgress() throws {
        let container = try makeProtocolTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let plan = TaskPlanPayload(
            title: "Plan",
            goal: "G",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect")
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let protocolEvent = AstraRunProtocolParsedEvent.valid(.planStep(.init(
            type: "plan.step.completed",
            planID: plan.planID.uuidString,
            stepID: "step-1",
            status: .done,
            summary: "Inspected files"
        )))
        AgentEventRecorder.recordClaudeRunEvent(.astraProtocol(protocolEvent), to: task, run: run, modelContext: context)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains { $0.type == "plan.step.completed" })
        #expect(run.output.isEmpty)
    }
}
