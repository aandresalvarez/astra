import SwiftUI

struct ChatPanelSlashOption: Identifiable {
    let id: String
    let command: String
    let icon: String
    let color: Color
    let title: String
    let description: String
    var executesImmediately = true

    static let all: [ChatPanelSlashOption] = [
        ChatPanelSlashOption(id: "skill", command: "/skill", icon: "puzzlepiece.extension", color: Stanford.lagunita,
                             title: "Create Skill", description: "Define agent behavior, allowed tools, and instructions"),
        ChatPanelSlashOption(id: "tool", command: "/tool", icon: "wrench.and.screwdriver", color: Stanford.plum,
                             title: "Create Tool", description: "Add a CLI command, script, or MCP tool"),
        ChatPanelSlashOption(id: "connector", command: "/connector", icon: "bolt.horizontal.circle", color: Stanford.paloAltoGreen,
                             title: "Create Connector", description: "Set up auth for Jira, GitHub, Slack, or APIs"),
        ChatPanelSlashOption(id: "template", command: "/template", icon: "rectangle.3.group", color: Stanford.poppy,
                             title: "Use Template", description: "Create a multi-phase task from a template"),
        ChatPanelSlashOption(id: "app", command: "/app", icon: "square.grid.2x2", color: Stanford.lagunita,
                             title: "Open App Studio", description: "Design a governed local app with storage, views, and actions"),
        ChatPanelSlashOption(id: "mcp", command: "/mcp", icon: "server.rack", color: Stanford.lagunita,
                             title: "Install MCP", description: "Review an MCP package, command, URL, or server JSON", executesImmediately: false),
        ChatPanelSlashOption(id: "schedule", command: "/routine", icon: "arrow.triangle.2.circlepath", color: Stanford.poppy,
                             title: "Create Routine", description: "Automate recurring work with instructions and capabilities"),
        ChatPanelSlashOption(id: "remember", command: "/remember", icon: "text.badge.checkmark", color: Stanford.lagunita,
                             title: "Add Memory", description: "Save a fact for the agent to remember in this workspace"),
        ChatPanelSlashOption(id: "recap", command: "/recap", icon: "doc.text", color: Stanford.paloAltoGreen,
                             title: "Recap Task", description: "Summarize this conversation so you can pause and resume later"),
    ]

    static func matching(_ rawInput: String) -> [ChatPanelSlashOption] {
        let filter = rawInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard filter != "/" else { return all }
        return all.filter { $0.command.hasPrefix(filter) }
    }
}

enum ChatPanelSlashCommandRouting {
    private static let commandTokens = [
        "/skill",
        "/tool",
        "/connector",
        "/template",
        "/routine",
        "/schedule",
        "/remember",
        "/recap",
        "/app",
        "/mcp"
    ]

    private static let providerContextTokens = [
        "/skill",
        "/tool",
        "/connector",
        "/template",
        "/routine",
        "/schedule"
    ]

    static func isSlashCommandInput(_ input: String) -> Bool {
        let lower = normalized(input)
        return commandTokens.contains { matches(lower, command: $0) }
    }

    static func providerContextCommand(for input: String) -> String? {
        let lower = normalized(input)
        return providerContextTokens.first { matches(lower, command: $0) }
    }

    static func selectionText(for option: ChatPanelSlashOption) -> String {
        option.executesImmediately ? option.command : "\(option.command) "
    }

    private static func normalized(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(_ input: String, command: String) -> Bool {
        input == command || input.hasPrefix(command + " ")
    }
}

struct ChatPanelSlashCommandMenu: View {
    let options: [ChatPanelSlashOption]
    @Binding var selectedIndex: Int
    let onSelect: (ChatPanelSlashOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                optionRow(option, at: index)

                if SlashCommandMenuPresentation.usesIconColumnDividers && index < options.count - 1 {
                    Divider()
                        .opacity(SlashCommandMenuPresentation.dividerOpacity)
                        .padding(.leading, SlashCommandMenuPresentation.dividerLeadingPadding)
                        .padding(.trailing, SlashCommandMenuPresentation.dividerTrailingPadding)
                }
            }
        }
        .padding(.vertical, SlashCommandMenuPresentation.menuVerticalPadding)
        .frame(maxWidth: SlashCommandMenuPresentation.maxWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SlashCommandMenuPresentation.menuCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SlashCommandMenuPresentation.menuCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(SlashCommandMenuPresentation.borderOpacity), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(SlashCommandMenuPresentation.shadowOpacity),
            radius: SlashCommandMenuPresentation.shadowRadius,
            y: SlashCommandMenuPresentation.shadowYOffset
        )
        .padding(.leading, 4)
    }

    private func optionRow(_ option: ChatPanelSlashOption, at index: Int) -> some View {
        Button {
            onSelect(option)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: option.icon)
                    .font(Stanford.ui(SlashCommandMenuPresentation.iconSize, weight: .semibold))
                    .foregroundStyle(option.color)
                    .frame(width: SlashCommandMenuPresentation.iconFrame)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.command)
                            .font(Stanford.ui(SlashCommandMenuPresentation.commandFontSize, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Stanford.black)
                        Text(option.title)
                            .font(Stanford.caption(SlashCommandMenuPresentation.titleFontSize))
                            .foregroundStyle(Stanford.coolGrey)
                            .lineLimit(1)
                    }
                    Text(option.description)
                        .font(Stanford.caption(SlashCommandMenuPresentation.descriptionFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(SlashCommandMenuPresentation.descriptionLineLimit)
                        .truncationMode(.tail)
                        .help(option.description)
                }
                Spacer()
                if index == selectedIndex {
                    Image(systemName: "return")
                        .font(Stanford.ui(SlashCommandMenuPresentation.returnIconSize))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, SlashCommandMenuPresentation.horizontalPadding)
            .frame(height: SlashCommandMenuPresentation.rowHeight)
            .background {
                if index == selectedIndex {
                    RoundedRectangle(cornerRadius: SlashCommandMenuPresentation.rowCornerRadius, style: .continuous)
                        .fill(Stanford.lagunita.opacity(SlashCommandMenuPresentation.selectedBackgroundOpacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
    }
}
