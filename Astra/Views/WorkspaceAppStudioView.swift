import SwiftUI

struct WorkspaceAppStudioView: View {
    let workspace: Workspace
    let initialIntent: String
    let existingManifest: WorkspaceAppManifest?
    let onCancel: () -> Void
    let onPublish: (WorkspaceAppStudioDraft) throws -> Void

    @State private var intent: String
    @State private var draft: WorkspaceAppStudioDraft
    @State private var ideas: [WorkspaceAppStudioIdea] = []
    @State private var statusMessage = ""
    @State private var isGeneratingDraft = false
    @State private var generationTask: Task<Void, Never>?
    @State private var isPreviewing = false
    @State private var isTesting = false

    // Generation provider + model. Bound to the same global default the task
    // composer uses, so picking a provider here (e.g. switching off an
    // unauthenticated Claude) carries across the app and is respected by generation.
    @AppStorage(AppStorageKeys.defaultRuntimeID) private var generationRuntimeID = TaskExecutionDefaults.runtime.rawValue
    @AppStorage(AppStorageKeys.defaultModel) private var generationModel = TaskExecutionDefaults.model
    @AppStorage(AppStorageKeys.runtimeModelCacheRevision) private var runtimeModelCacheRevision = 0

    init(
        workspace: Workspace,
        initialIntent: String = WorkspaceAppStudioBuilder.defaultIntent,
        existingManifest: WorkspaceAppManifest? = nil,
        onCancel: @escaping () -> Void,
        onPublish: @escaping (WorkspaceAppStudioDraft) throws -> Void
    ) {
        self.workspace = workspace
        self.initialIntent = initialIntent
        self.existingManifest = existingManifest
        self.onCancel = onCancel
        self.onPublish = onPublish
        let generatedDraft = WorkspaceAppStudioBuilder.draft(
            intent: initialIntent,
            workspace: workspace,
            existingManifest: existingManifest
        )
        _intent = State(initialValue: generatedDraft.intent)
        _draft = State(initialValue: generatedDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intentSection
                    ideasSection
                    proposalSection
                    inlinePreviewSection
                    validationSection
                    manifestSection
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppStudioView")
        .onDisappear { generationTask?.cancel() }
        .sheet(isPresented: $isPreviewing) {
            WorkspaceAppPreviewView(manifest: draft.manifest) { isPreviewing = false }
        }
        .sheet(isPresented: $isTesting) {
            WorkspaceAppTestPanelView(
                manifest: draft.manifest,
                workspacePath: workspace.primaryPath,
                onSaveChecks: { draft.manifest.checks = $0.isEmpty ? nil : $0 }
            ) { isTesting = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("App Studio")
                    .font(Stanford.heading(20))
                    .foregroundStyle(.primary)

                Text(workspace.name)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)

            Button(action: { isPreviewing = true }) {
                Label("Preview", systemImage: "play.rectangle")
            }
            .buttonStyle(.bordered)
            .help("Open the full app in a sandbox to test it before publishing — nothing is saved")

            Button(action: { isTesting = true }) {
                Label("Test", systemImage: "checkmark.seal")
            }
            .buttonStyle(.bordered)
            .help("Check the app works as expected: self-check every action, or describe a test in plain English")

            Button(action: publishDraft) {
                Label("Publish", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.canPublish)
            .help(draft.canPublish ? "Publish this Workspace App" : "Resolve validation blockers before publishing")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Intent", count: nil)

            typePickerRow

            TextEditor(text: $intent)
                .font(Stanford.ui(14))
                .frame(minHeight: 92)
                .disabled(isGeneratingDraft)
                .padding(8)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button(action: regenerateDraft) {
                    if isGeneratingDraft {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Generate Draft", systemImage: "wand.and.sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingDraft)

                Button(action: generateIdeas) {
                    Label("Ideate", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingDraft)

                WorkspaceAppStudioModelPicker(
                    runtimeID: $generationRuntimeID,
                    model: $generationModel,
                    cacheRevision: runtimeModelCacheRevision
                )
                .disabled(isGeneratingDraft)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }

            // Honest scope guard: a website/marketing intent can't be expressed by the
            // data-app schema, so say so instead of silently shipping a data shell.
            if let scopeNotice {
                WorkspaceAppDetailNotice(
                    title: "This looks like a website, not a data app",
                    message: scopeNotice,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private var scopeNotice: String? {
        WorkspaceAppStudioScope.outOfScopeNotice(for: intent)
    }

    @ViewBuilder
    private var ideasSection: some View {
        if !ideas.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Ideas", count: ideas.count)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(ideas) { idea in
                        ideaCard(idea)
                    }
                }
            }
        }
    }

    private var proposalSection: some View {
        let identity = WorkspaceAppStudioIdentityBuilder.identity(for: draft.manifest, report: draft.validationReport)
        let refinements = WorkspaceAppStudioRefinement.allCases.filter { $0.isAvailable(for: draft.manifest) }
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Your app", count: nil)
            identityCard(identity)
            if !refinements.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Refine it")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(refinements) { refinement in
                            Button(action: { applyRefinement(refinement) }) {
                                Label(refinement.label, systemImage: refinement.iconSystemName)
                                    .font(Stanford.caption(12))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isGeneratingDraft)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func identityCard(_ identity: WorkspaceAppStudioIdentityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: identity.iconSystemName)
                    .font(Stanford.ui(22, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 44, height: 44)
                    .background(Stanford.lagunita.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.archetypeLabel)
                        .font(Stanford.caption(12).weight(.semibold))
                        .foregroundStyle(Stanford.lagunita)
                    Text(identity.name)
                        .font(Stanford.ui(17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(identity.purpose)
                        .font(Stanford.caption(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(identity.permissionSummary, systemImage: identity.permissionIcon)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("What you'll be able to do")
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(identity.capabilities, id: \.self) { capability in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.lagunita)
                        Text(capability)
                            .font(Stanford.caption(13))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var inlinePreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Preview", count: nil)
            WorkspaceAppStudioInlinePreview(manifest: draft.manifest)
        }
    }

    private var typePickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WorkspaceAppArchetype.allCases, id: \.self) { archetype in
                    Button(action: { selectArchetype(archetype) }) {
                        Label(archetype.displayName, systemImage: archetype.iconSystemName)
                            .font(Stanford.caption(12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isGeneratingDraft)
                    .help(archetype.tagline)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func selectArchetype(_ archetype: WorkspaceAppArchetype) {
        intent = archetype.exampleIntent
        regenerateDraft()
    }

    private func applyRefinement(_ refinement: WorkspaceAppStudioRefinement) {
        let updated = refinement.apply(to: draft.manifest)
        draft = WorkspaceAppStudioBuilder.draft(intent: draft.intent, workspace: workspace, existingManifest: updated)
        statusMessage = "Applied: \(refinement.label)"
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Validation",
                count: draft.validationReport.issues.isEmpty ? nil : draft.validationReport.issues.count
            )

            if draft.validationReport.issues.isEmpty {
                WorkspaceAppDetailNotice(
                    title: "Ready to publish",
                    message: "The manifest is valid. Schedules remain disabled until explicitly enabled.",
                    systemImage: "checkmark.seal"
                )
            } else {
                ForEach(Array(draft.validationReport.issues.enumerated()), id: \.offset) { _, issue in
                    WorkspaceAppDetailNotice(
                        title: issue.severity.rawValue.capitalized,
                        message: "\(issue.path): \(issue.message)",
                        systemImage: issue.severity == .blocker ? "xmark.octagon" : "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var manifestSection: some View {
        let inspector = WorkspaceAppManifestInspectorPresentationBuilder.presentation(
            manifest: draft.manifest,
            validationReport: draft.validationReport
        )
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                inspectorGroup("Identity", rows: inspector.identity)
                inspectorGroup("Sources", rows: inspector.sources)
                inspectorGroup("Storage", rows: inspector.storage)
                inspectorGroup("Actions", rows: inspector.actions)
                inspectorGroup("Automations", rows: inspector.automations)
                inspectorGroup("Permissions", rows: inspector.permissions)
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced — storage, actions, permissions, raw manifest")
                .font(Stanford.caption(13).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Stanford.caption(13).weight(.semibold))
                .foregroundStyle(.primary)
            if let count {
                Text("\(count)")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func ideaCard(_ idea: WorkspaceAppStudioIdea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(idea.name)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(idea.riskMode.rawValue)
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(idea.problem)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(idea.accelerationRationale)
                .font(Stanford.caption(11))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label("\(idea.requiredSources.count)", systemImage: "point.3.connected.trianglepath.dotted")
                Label("\(idea.actions.count)", systemImage: "play.circle")
                Label("\(idea.automation.count)", systemImage: "clock")
                Spacer()
                Button("Use", action: { useIdea(idea) })
                    .buttonStyle(.borderless)
            }
            .font(Stanford.caption(11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func inspectorGroup(
        _ title: String,
        rows: [WorkspaceAppInspectorRowPresentation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)

                Text("\(rows.count)")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if rows.isEmpty {
                Text("None")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.title)
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(row.detail)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func regenerateDraft() {
        // Snapshot the intent at click time: edits to the intent field while a
        // generation is in flight are ignored (the field is disabled meanwhile);
        // the user can Generate again to incorporate new edits.
        let currentIntent = intent
        let workspaceName = workspace.name
        let workspacePath = workspace.primaryPath
        let existing = existingManifest
        // Build the generation config from the chosen provider + model (instead of the
        // hardcoded Claude default), so the picker actually routes generation.
        let configuration = AgentUtilityRuntimeConfiguration(
            runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: generationRuntimeID),
            model: generationModel
        )
        isGeneratingDraft = true
        statusMessage = "Generating draft…"
        generationTask = Task { @MainActor in
            let result = await WorkspaceAppStudioGenerator.generate(
                intent: currentIntent,
                workspaceName: workspaceName,
                workspacePath: workspacePath,
                existingManifest: existing,
                configuration: configuration
            )
            // Dismissed mid-generation: onDisappear cancelled us and the runtime
            // subprocess is already torn down, so drop the result instead of
            // mutating @State on a view that has left the tree.
            guard !Task.isCancelled else { return }
            // Wrap the (always-valid) model/fallback manifest into a draft so the
            // proposal + validation panels rebuild from it; the validator is the
            // authoritative publish gate.
            draft = WorkspaceAppStudioBuilder.draft(
                intent: currentIntent,
                workspace: workspace,
                existingManifest: result.manifest
            )
            statusMessage = Self.statusLine(for: result, isEditing: existing != nil)
            isGeneratingDraft = false
        }
    }

    private static func statusLine(
        for result: WorkspaceAppStudioGenerationResult,
        isEditing: Bool
    ) -> String {
        switch result.origin {
        case .model:
            return "Draft generated by the model."
        case .modelRepaired:
            return "Draft generated (repaired in \(result.attemptCount) attempts)."
        case .deterministicFallback:
            // In the editing case the fallback IS the user's existing app, not a template.
            let degraded = isEditing ? "your current app definition is unchanged" : "using a template draft"
            // providerFailure now always carries the real reason (a provider error, a
            // markerless reply, a decode error, or the first validation blocker).
            if let failure = result.providerFailure {
                return "Couldn't build from the model — \(degraded). (\(failure))"
            }
            return "Couldn't build from the model — \(degraded)."
        }
    }

    private func generateIdeas() {
        ideas = WorkspaceAppStudioIdeator.proposals(for: WorkspaceAppStudioIdeationContext(userRequest: intent))
        statusMessage = "\(ideas.count) ideas generated."
    }

    private func useIdea(_ idea: WorkspaceAppStudioIdea) {
        draft = WorkspaceAppStudioBuilder.draft(from: idea, workspace: workspace)
        intent = idea.accelerationRationale
        statusMessage = "Idea converted to draft."
    }

    private func publishDraft() {
        do {
            try onPublish(draft)
            statusMessage = "Published."
        } catch {
            statusMessage = String(describing: error)
        }
    }
}
