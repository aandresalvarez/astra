import SwiftUI

/// App Studio as a conversation (the Lovable/Replit left pane). You describe the app, the
/// model builds it, and you refine it by chatting — while the live app renders in the docked
/// preview shelf on the right. This is a thin renderer over `WorkspaceAppStudioSession`: it
/// reuses the same model picker the task composer uses, the archetype quick-starts, and the
/// `WorkspaceAppStudioRefinement` chips (now things you can just say). Publishing and
/// sample-data seeding are handed back to ContentView via callbacks.
struct WorkspaceAppStudioChatView: View {
    @ObservedObject var session: WorkspaceAppStudioSession
    let workspace: Workspace
    let onPublish: (_ seedSampleData: Bool) -> Void
    let onCancel: () -> Void

    // Generation provider + model: bound to the same global default the task composer uses,
    // so a provider choice carries across the app and routes generation here too.
    @AppStorage(AppStorageKeys.defaultRuntimeID) private var runtimeID = TaskExecutionDefaults.runtime.rawValue
    @AppStorage(AppStorageKeys.defaultModel) private var model = TaskExecutionDefaults.model
    @AppStorage(AppStorageKeys.runtimeModelCacheRevision) private var runtimeModelCacheRevision = 0

    @State private var inputText = ""
    @State private var seedSampleData = false
    @State private var isTesting = false
    @State private var isInspecting = false
    @State private var appliedInitialPrompt: String?
    @FocusState private var composerFocused: Bool

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isGenerating
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composerArea
        }
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppStudioChatView")
        .onAppear {
            applyInitialPromptIfNeeded()
            composerFocused = true
        }
        .onChange(of: session.initialPrompt) { _, _ in applyInitialPromptIfNeeded() }
        .onChange(of: inputText) { _, _ in applyInitialPromptIfNeeded() }
        .sheet(isPresented: $isTesting) {
            if let draft = session.draft {
                WorkspaceAppTestPanelView(
                    manifest: draft.manifest,
                    workspacePath: workspace.primaryPath,
                    onSaveChecks: { session.applyChecks($0, workspace: workspace) },
                    onDismiss: { isTesting = false }
                )
            }
        }
        .sheet(isPresented: $isInspecting) {
            if let draft = session.draft {
                WorkspaceAppManifestInspectorView(
                    manifest: draft.manifest,
                    validationReport: draft.validationReport,
                    onDismiss: { isInspecting = false }
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Studio")
                    .font(Stanford.heading(20))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                Text(session.appName ?? workspace.name)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)

            Toggle(isOn: $seedSampleData) {
                Text("Sample data").font(Stanford.caption(12)).lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .help("Seed a few example rows on publish so the app isn't empty. You can delete them anytime.")

            Menu {
                Button { isTesting = true } label: { Label("Test app…", systemImage: "checkmark.seal") }
                Button { isInspecting = true } label: { Label("Inspect manifest…", systemImage: "doc.text.magnifyingglass") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.draft == nil)
            .help("Test the app, or inspect its manifest")

            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)

            Button(action: { onPublish(seedSampleData) }) {
                Label("Publish", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.canPublish)
            .help(session.canPublish ? "Publish this app into \(workspace.name)" : "Describe an app and resolve any blockers first")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if session.isGenerating {
                        generatingIndicator.id("studio.generating")
                    } else if session.isVerifying {
                        verifyingIndicator.id("studio.verifying")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: session.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.isGenerating) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.isVerifying) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if session.isGenerating {
                proxy.scrollTo("studio.generating", anchor: .bottom)
            } else if let last = session.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func bubble(_ message: StudioMessage) -> some View {
        let isUser = message.role == .user
        return HStack(spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            Text(message.text)
                .font(Stanford.ui(13))
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground(message))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !isUser { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func bubbleBackground(_ message: StudioMessage) -> Color {
        if message.role == .user { return Stanford.lagunita }
        return message.kind == .summary ? Stanford.lagunita.opacity(0.08) : Color.primary.opacity(0.05)
    }

    private var generatingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Building your app…")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
    }

    private var verifyingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking your change in a sandbox…")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            suggestions
            HStack(spacing: 10) {
                TextField(
                    session.draft == nil ? "Describe the app you want…" : "Describe a change…",
                    text: $inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(Stanford.ui(13))
                .focused($composerFocused)
                .disabled(session.isGenerating)
                .onSubmit { send(inputText) }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityIdentifier("WorkspaceAppStudioComposerInput")

                WorkspaceAppStudioModelPicker(
                    runtimeID: $runtimeID,
                    model: $model,
                    cacheRevision: runtimeModelCacheRevision
                )
                .disabled(session.isGenerating)

                Button(action: { send(inputText) }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Stanford.ui(22))
                        .foregroundStyle(canSend ? Stanford.lagunita : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Before the first app exists: archetype quick-starts. After: the refinement chips that
    /// still apply — both just send/apply, so the conversation reads naturally.
    @ViewBuilder
    private var suggestions: some View {
        if session.isGenerating {
            EmptyView()
        } else if session.draft == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(WorkspaceAppArchetype.allCases, id: \.self) { archetype in
                        Button(action: { send(archetype.exampleIntent) }) {
                            Label(archetype.displayName, systemImage: archetype.iconSystemName)
                                .font(Stanford.caption(12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(archetype.tagline)
                    }
                }
                .padding(.vertical, 1)
            }
        } else {
            let refinements = session.availableSuggestions
            if !refinements.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(refinements) { refinement in
                            Button(action: { session.applyRefinement(refinement, workspace: workspace) }) {
                                Label(refinement.label, systemImage: refinement.iconSystemName)
                                    .font(Stanford.caption(12))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isGenerating else { return }
        inputText = ""
        // Capability-aware generation: tell the model which connectors this workspace has.
        let providers = Set(
            CapabilityRuntimeResourceMatcher.enabledPackages(for: workspace)
                .flatMap { $0.connectors.map(\.serviceType) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
        Task {
            await session.submit(
                trimmed,
                workspace: workspace,
                runtimeID: runtimeID,
                model: model,
                availableProviders: providers
            )
            // If the selected provider failed (401/timeout) and the generator auto-fell-back to a
            // working one, adopt it into the picker so it reflects reality AND subsequent turns skip
            // the dead provider (no per-turn timeout/401 cost). The user can switch back any time.
            if let resolved = session.lastResolvedRuntimeID, resolved != runtimeID {
                runtimeID = resolved
                model = AgentRuntimeAdapterRegistry.defaultModel(
                    for: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: resolved)
                )
            }
        }
    }

    private func applyInitialPromptIfNeeded() {
        WorkspaceAppStudioInitialPromptApplicator.apply(
            initialPrompt: session.initialPrompt,
            inputText: &inputText,
            appliedInitialPrompt: &appliedInitialPrompt
        )
    }
}

enum WorkspaceAppStudioInitialPromptApplicator {
    static func apply(
        initialPrompt: String?,
        inputText: inout String,
        appliedInitialPrompt: inout String?
    ) {
        let normalized = WorkspaceAppStudioLaunchRequest.normalizedPrompt(initialPrompt)
        guard appliedInitialPrompt != normalized else { return }
        guard let normalized else {
            appliedInitialPrompt = nil
            return
        }
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        inputText = normalized
        appliedInitialPrompt = normalized
    }
}
