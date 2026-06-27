import SwiftUI
import SwiftData
import ASTRACore

struct CapabilityMCPInstallReviewSheet: View {
    let request: MCPInstallChatRequest
    let workspace: Workspace
    let onCancel: () -> Void
    let onInstalled: (PluginPackage) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var draft: CapabilityMCPServerDraft
    @State private var errorMessage: String?

    private let decision: MCPInstallPolicyDecision

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
        _draft = State(initialValue: Self.draft(from: request.intent))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    policySection
                    CapabilityMCPServerDraftEditor(
                        draft: $draft,
                        declaredEnvironmentKeys: [],
                        validationMessage: errorMessage
                    )
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
            let server = try draft.makeServer()
            var package = try MCPInstallPackageBuilder.package(from: request.intent)
            package.mcpServers = [server]
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

    private static func draft(from intent: MCPInstallIntent) -> CapabilityMCPServerDraft {
        var draft = CapabilityMCPServerDraft()
        draft.serverID = intent.serverID ?? "mcp"
        draft.displayName = intent.displayName ?? intent.serverID ?? "MCP"
        draft.transport = intent.transport
        draft.command = intent.command ?? ""
        draft.argumentsText = intent.arguments.joined(separator: "\n")
        draft.urlText = intent.url?.absoluteString ?? ""
        draft.installSource = intent.installSource
        return draft
    }
}
