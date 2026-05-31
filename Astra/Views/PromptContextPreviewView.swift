import SwiftUI
import AppKit

struct PromptContextPreviewSummary: Equatable {
    var modeText: String
    var tokenText: String
    var sectionText: String
    var truncationText: String
    var characterText: String
}

struct PromptContextPreviewRequest: Equatable {
    enum Kind: Equatable {
        case initialRun
        case followUp
        case unavailable
    }

    var kind: Kind
    var followUpMessage: String?
    var unavailableReason: String?
}

enum PromptContextPreviewPresentation {
    static let defaultResumeMessage = "Continue where you left off. Complete the original goal."

    static func request(
        taskStatus: TaskStatus,
        hasProviderSession: Bool,
        messageText: String,
        attachedFiles: [String]
    ) -> PromptContextPreviewRequest {
        let hasDraftFollowUp = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
        if isFollowUpStatus(taskStatus), hasDraftFollowUp {
            return PromptContextPreviewRequest(
                kind: .followUp,
                followUpMessage: messageWithAttachedFiles(messageText, attachedFiles: attachedFiles),
                unavailableReason: nil
            )
        }

        if (taskStatus == .failed || taskStatus == .budgetExceeded), hasProviderSession {
            return PromptContextPreviewRequest(
                kind: .followUp,
                followUpMessage: defaultResumeMessage,
                unavailableReason: nil
            )
        }

        if taskStatus == .queued {
            return PromptContextPreviewRequest(kind: .initialRun, followUpMessage: nil, unavailableReason: nil)
        }

        return PromptContextPreviewRequest(
            kind: .unavailable,
            followUpMessage: nil,
            unavailableReason: "No provider prompt is pending. Type a follow-up message to preview what will be sent."
        )
    }

    static func summary(for manifest: PromptAssemblyManifest) -> PromptContextPreviewSummary {
        PromptContextPreviewSummary(
            modeText: manifest.mode.displayName,
            tokenText: "\(Formatters.formatTokens(manifest.estimatedPromptTokens)) tokens",
            sectionText: "\(manifest.sections.count) section\(manifest.sections.count == 1 ? "" : "s")",
            truncationText: "\(manifest.truncatedSectionCount) truncated",
            characterText: "\(manifest.promptCharacterCount) chars"
        )
    }

    static func budgetText(for section: PromptAssemblySectionManifest) -> String {
        "\(Formatters.formatTokens(section.estimatedIncludedTokens)) / \(Formatters.formatTokens(section.tokenBudget))"
    }

    static func originalText(for section: PromptAssemblySectionManifest) -> String {
        "\(Formatters.formatTokens(section.estimatedOriginalTokens)) original"
    }

    static func sourcePointerText(for section: PromptAssemblySectionManifest) -> String {
        "\(section.sourcePointers.count) source\(section.sourcePointers.count == 1 ? "" : "s")"
    }

    static func truncationLabel(for section: PromptAssemblySectionManifest) -> String {
        section.isTruncated ? "Truncated" : "Included"
    }

    private static func isFollowUpStatus(_ status: TaskStatus) -> Bool {
        switch status {
        case .pendingUser, .completed, .failed, .budgetExceeded, .cancelled:
            return true
        case .draft, .queued, .running:
            return false
        }
    }

    private static func messageWithAttachedFiles(_ messageText: String, attachedFiles: [String]) -> String {
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachedFiles.isEmpty else { return trimmedMessage }
        let fileList = attachedFiles.map { "- \($0)" }.joined(separator: "\n")
        let attachmentText = "Attached files:\n\(fileList)"
        guard !trimmedMessage.isEmpty else { return attachmentText }
        return trimmedMessage + "\n\n" + attachmentText
    }
}

struct PromptContextPreviewSheet: View {
    let manifest: PromptAssemblyManifest
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSectionIndexes: Set<Int> = [0]
    @State private var isFullPromptExpanded = false
    @State private var didCopyPrompt = false

    private var summary: PromptContextPreviewSummary {
        PromptContextPreviewPresentation.summary(for: manifest)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryGrid
                    sectionsList
                    fullPromptDisclosure
                }
                .padding(18)
            }

            Divider()

            footer
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("ContextPreviewSheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(Stanford.ui(21, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Context Preview")
                    .font(Stanford.heading(18))
                    .foregroundStyle(Stanford.black)
                Text(summary.modeText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                copyPrompt()
            } label: {
                Label(didCopyPrompt ? "Copied" : "Copy Prompt", systemImage: didCopyPrompt ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .controlSize(.small)
            .help("Copy the assembled prompt")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(StanfordButtonStyle())
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var summaryGrid: some View {
        HStack(spacing: 10) {
            summaryPill(title: "Mode", value: summary.modeText, icon: "arrow.triangle.branch")
            summaryPill(title: "Budget", value: summary.tokenText, icon: "circle.dashed")
            summaryPill(title: "Sections", value: summary.sectionText, icon: "rectangle.stack")
            summaryPill(title: "Trim", value: summary.truncationText, icon: "scissors")
        }
    }

    private func summaryPill(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.readingText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var sectionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt Sections")
                .font(Stanford.chatSection())
                .foregroundStyle(Stanford.black)

            VStack(spacing: 0) {
                ForEach(Array(manifest.sections.enumerated()), id: \.offset) { index, section in
                    sectionDisclosure(section, index: index)
                    if index != manifest.sections.count - 1 {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func sectionDisclosure(_ section: PromptAssemblySectionManifest, index: Int) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: index)) {
            sectionDetails(section)
                .padding(.leading, 27)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: sectionIcon(for: section.kind))
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(section.isTruncated ? Stanford.poppy : Stanford.lagunita)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.displayName.capitalized)
                        .font(Stanford.body(13).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text("\(PromptContextPreviewPresentation.budgetText(for: section)) tokens")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(PromptContextPreviewPresentation.truncationLabel(for: section))
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(section.isTruncated ? Stanford.poppy : Stanford.paloAltoGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((section.isTruncated ? Stanford.poppy : Stanford.paloAltoGreen).opacity(0.10))
                    .clipShape(Capsule())
            }
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.leading, 12)
    }

    private func sectionDetails(_ section: PromptAssemblySectionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                sectionFact("Included", PromptContextPreviewPresentation.budgetText(for: section))
                sectionFact("Original", PromptContextPreviewPresentation.originalText(for: section))
                sectionFact("Sources", PromptContextPreviewPresentation.sourcePointerText(for: section))
            }

            if !section.sourcePointers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Source Pointers")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(section.sourcePointers.enumerated()), id: \.offset) { _, pointer in
                        sourcePointerRow(pointer)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Included Text")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(section.includedTextPreview)
                    .font(Stanford.chatRaw(11))
                    .foregroundStyle(Stanford.readingText)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private func sectionFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Stanford.caption(10).weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(Stanford.readingText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourcePointerRow(_ pointer: PromptAssemblySourcePointer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pointer.label)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
            Text(pointer.target)
                .font(Stanford.chatRaw(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullPromptDisclosure: some View {
        DisclosureGroup(isExpanded: $isFullPromptExpanded) {
            Text(fullPromptPreview)
                .font(Stanford.chatRaw(11))
                .foregroundStyle(Stanford.readingText)
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 6)
        } label: {
            HStack {
                Label("Full Prompt", systemImage: "doc.plaintext")
                    .font(Stanford.chatSection())
                    .foregroundStyle(Stanford.black)
                Spacer()
                Text(summary.characterText)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var fullPromptPreview: String {
        guard manifest.prompt.count > 12_000 else { return manifest.prompt }
        return String(manifest.prompt.prefix(12_000)) + "\n... (preview truncated; copy prompt for full text)"
    }

    private var footer: some View {
        HStack {
            Text("\(summary.tokenText) across \(summary.sectionText.lowercased())")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(summary.truncationText)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(manifest.truncatedSectionCount > 0 ? Stanford.poppy : Stanford.paloAltoGreen)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func expansionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { expandedSectionIndexes.contains(index) },
            set: { isExpanded in
                if isExpanded {
                    expandedSectionIndexes.insert(index)
                } else {
                    expandedSectionIndexes.remove(index)
                }
            }
        )
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manifest.prompt, forType: .string)
        didCopyPrompt = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { didCopyPrompt = false }
        }
    }

    private func sectionIcon(for kind: PromptContextSectionKind) -> String {
        switch kind {
        case .currentGoal: return "target"
        case .threadState: return "list.clipboard"
        case .recentTranscript: return "text.bubble"
        case .changedFiles: return "doc.text"
        case .tools: return "wrench.and.screwdriver"
        case .browser: return "safari"
        case .memories: return "brain"
        case .supportingContext: return "info.circle"
        }
    }
}

struct PromptContextPreviewUnavailableSheet: View {
    let reason: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(Stanford.ui(21, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Context Preview")
                        .font(Stanford.heading(18))
                        .foregroundStyle(Stanford.black)
                    Text("No pending prompt")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(StanfordButtonStyle())
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Nothing will be sent yet", systemImage: "pause.circle")
                    .font(Stanford.body(14).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(reason)
                    .font(Stanford.body(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)

            Spacer(minLength: 0)
        }
        .frame(minWidth: 520, minHeight: 260)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("ContextPreviewUnavailableSheet")
    }
}
