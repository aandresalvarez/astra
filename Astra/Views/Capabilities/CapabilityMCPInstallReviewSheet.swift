import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

struct CapabilityMCPInstallReviewSheet: View {
    let request: MCPInstallChatRequest
    let workspace: Workspace
    let onCancel: () -> Void
    let onInstalled: (PluginPackage) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var draft: CapabilityMCPServerDraft
    @State private var errorMessage: String?

    private let decision: MCPInstallPolicyDecision
    private let declaredEnvironmentKeys: Set<String>

    init(
        request: MCPInstallChatRequest,
        workspace: Workspace,
        onCancel: @escaping () -> Void,
        onInstalled: @escaping (PluginPackage) -> Void
    ) {
        self.request = request
        self.workspace = workspace
        self.onCancel = onCancel
        self.onInstalled = onInstalled
        self.decision = MCPInstallPolicy.decision(for: request.intent)
        let draftState = CapabilityMCPInstallReviewDraftFactory.draftState(from: request.intent)
        self.declaredEnvironmentKeys = draftState.declaredEnvironmentKeys
        _draft = State(initialValue: draftState.draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    policySection
                    reviewSection
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 640)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(Stanford.ui(16, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 34, height: 34)
                .background(Stanford.lagunita.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("Review MCP Install")
                    .font(Stanford.heading(18))
                Text(request.intent.installSource?.identifier ?? request.intent.rawInput)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(18)
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(decision.summary)
                .font(Stanford.body(13))
                .foregroundStyle(.primary)
            if decision.blockers.isEmpty && decision.warnings.isEmpty {
                Label("Ready for local draft review", systemImage: "checkmark.seal.fill")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.lagunita)
            }
            ForEach(decision.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "xmark.octagon.fill")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.cardinalRed)
            }
            ForEach(decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.poppy)
            }
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if decision.requiresGuidedSetup {
            guidedSetupSection
        } else if request.intent.serverSpecs.count == 1 {
            CapabilityMCPServerDraftEditor(
                draft: $draft,
                declaredEnvironmentKeys: declaredEnvironmentKeys,
                validationMessage: errorMessage
            )
        } else {
            parsedServersSection
        }
    }

    private var guidedSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Run setup, then paste the generated mcpServers JSON.", systemImage: "gearshape.2")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            if let setupCommand = request.intent.setupCommand {
                Text(([setupCommand.command] + setupCommand.arguments).joined(separator: " "))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var parsedServersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parsed MCP servers")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(Array(request.intent.serverSpecs.enumerated()), id: \.offset) { _, spec in
                HStack(spacing: 10) {
                    Image(systemName: spec.transport == .stdio ? "terminal" : "network")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.displayName ?? spec.serverID)
                            .font(.system(size: 12, weight: .semibold))
                        Text(serverSummary(spec))
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Stanford.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.cardinalRed)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                install()
            } label: {
                Label("Save Capability", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(Stanford.lagunita)
            .disabled(!decision.canReview)
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private func install() {
        do {
            var package = try MCPInstallPackageBuilder.package(from: request.intent)
            if request.intent.serverSpecs.count == 1 {
                let server = try draft.makeServer(declaredEnvironmentKeys: declaredEnvironmentKeys)
                package.mcpServers = [server]
            }
            let result = try CapabilityPackageCreationService().create(
                package,
                enableHere: false,
                sourceURL: nil,
                workspace: workspace,
                modelContext: modelContext,
                traceID: AuditTrace.make("mcp-chat-install-review")
            )
            onInstalled(result.package)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func serverSummary(_ spec: MCPInstallServerSpec) -> String {
        switch spec.transport {
        case .stdio:
            return ([spec.command ?? ""] + spec.arguments)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .http, .sse:
            return spec.url?.absoluteString ?? spec.transport.rawValue
        }
    }
}
