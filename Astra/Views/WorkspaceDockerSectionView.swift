import SwiftUI

struct WorkspaceDockerSectionView: View {
    @StateObject var viewModel = WorkspaceDockerViewModel()
    let workspace: Workspace
    var selectedTask: AgentTask?
    var isCompact = false

    private static let rowIconGlyphSize = CapabilityRailLayout.leadingIconFontSize
    private static let rowIconFrame = CapabilityRailLayout.leadingIconFrame
    private static let rowIconSpacing = CapabilityRailLayout.leadingIconSpacing

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: isCompact
                ? CapabilityRailLayout.compactSectionContentSpacing
                : CapabilityRailLayout.regularSectionContentSpacing
        ) {
            header

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            if let status = viewModel.statusMessage {
                infoBanner(status)
            }

            environmentPickerRow

            if viewModel.shouldShowCredentialProjectionRow {
                rowDivider
                credentialProjectionRow
            }

            if viewModel.buildRequest != nil {
                rowDivider
                buildActionRow
            }

            if let title = viewModel.dockerIssueTitle,
               let subtitle = viewModel.dockerIssueSubtitle {
                rowDivider
                dockerIssueRow(title: title, subtitle: subtitle, detail: viewModel.imageInventoryIssue)
            }

            if let detected = viewModel.detectedSummary {
                rowDivider
                detectedSummaryRow(detected)
            }
        }
        .onAppear {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
        }
        .onChange(of: selectedTask?.id) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
        }
        .onChange(of: selectedTask?.status) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
        }
        .onChange(of: workspace.primaryPath) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
        }
        .onChange(of: workspace.additionalPaths) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
        }
        .onChange(of: workspace.activeExecutionEnvironmentJSON) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Container")
                .font(Stanford.ui(CapabilityRailLayout.sectionTitleFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Stanford.ui(CapabilityRailLayout.sectionActionFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .help("Refresh containers")
            }
        }
    }

    private var environmentPickerRow: some View {
        Menu {
            ForEach(viewModel.environmentOptions) { option in
                Button {
                    viewModel.selectEnvironmentOption(option.id)
                } label: {
                    Label(option.title, systemImage: option.isSelected ? "checkmark" : option.iconSystemName)
                }
                .disabled(!option.isEnabled || option.isSelected)
                .help(option.help)
            }
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon(viewModel.selectedEnvironment.isContainerized ? "shippingbox.fill" : "desktopcomputer")

                VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                    rowTitle(viewModel.environmentPickerTitle)
                    Text(viewModel.environmentPickerSubtitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                RailCountBadge(viewModel.activeScopeLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
                    .foregroundStyle(viewModel.canChangeActiveEnvironment ? Stanford.lagunita : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.summaryRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canChangeActiveEnvironment)
        .help(viewModel.environmentPickerHelp)
    }

    private var credentialProjectionRow: some View {
        Button {
            viewModel.toggleGCPADCProjection()
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon("key.fill", color: viewModel.credentialProjectionIsEnabled ? Stanford.lagunita : .secondary)

                VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                    rowTitle(viewModel.credentialProjectionTitle)
                    Text(viewModel.credentialProjectionSubtitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Image(systemName: viewModel.credentialProjectionActionSystemName)
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize + 2, weight: .semibold))
                    .foregroundStyle(viewModel.credentialProjectionIsEnabled ? Stanford.lagunita : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.setupRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.credentialProjectionIsEnabled)
        .help(viewModel.credentialProjectionHelp)
    }

    private var buildActionRow: some View {
        Button {
            Task { await viewModel.buildWorkspaceImage() }
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                if viewModel.isBuildingImage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Self.rowIconFrame)
                } else {
                    rowIcon("hammer.fill", color: Stanford.lagunita)
                }
                VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                    rowTitle(viewModel.setupActionTitle)
                    Text(viewModel.setupActionSubtitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(viewModel.setupActionSubtitle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Image(systemName: viewModel.isBuildingImage ? "hourglass" : "play.circle.fill")
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize + 2, weight: .semibold))
                    .foregroundStyle(viewModel.isBuildingImage ? .secondary : Stanford.lagunita)
            }
            .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.setupRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBuildingImage)
        .help(viewModel.setupActionHelp)
    }

    private func dockerIssueRow(title: String, subtitle: String, detail: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(Self.rowIconGlyphSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.rowIconFrame)
            VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                rowTitle(title)
                Text(subtitle)
                    .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.setupRowMinHeight, alignment: .leading)
        .help(detail ?? subtitle)
    }

    private func detectedSummaryRow(_ title: String) -> some View {
        HStack(spacing: Self.rowIconSpacing) {
            rowIcon("shippingbox", color: .secondary)
            VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                rowTitle(title)
                Text("Only loaded Docker images can run workspace commands right now.")
                    .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.setupRowMinHeight, alignment: .leading)
    }

    private var rowDivider: some View {
        Divider()
            .opacity(0.22)
            .padding(.leading, Self.rowIconFrame)
    }

    private func rowIcon(_ name: String, color: Color = Stanford.lagunita) -> some View {
        Image(systemName: name)
            .font(Stanford.ui(Self.rowIconGlyphSize, weight: .medium))
            .foregroundStyle(color)
            .frame(width: Self.rowIconFrame)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(Stanford.ui(CapabilityRailLayout.rowTitleFontSize, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Stanford.errorRed)
                .font(Stanford.ui(12))
            Text(message)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.errorRed)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .bold))
                    .foregroundStyle(Stanford.errorRed.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.errorRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func infoBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Stanford.statusHealthy)
                .font(Stanford.ui(12))
            Text(message)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                viewModel.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.statusHealthy.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
