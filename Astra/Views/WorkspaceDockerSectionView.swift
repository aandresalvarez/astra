import ASTRACore
import SwiftUI
import ASTRAModels

/// The container rows of the Environment box (rail v2): where new tasks run,
/// what that means for the provider and project commands, and the image and
/// Docker state behind it. The rail owns the view model and the box header
/// carries the refresh control, so these are rows, not a card.
struct WorkspaceDockerSectionView: View {
    private typealias Layout = WorkspaceRailSectionPresentation.Layout

    @ObservedObject var viewModel: WorkspaceDockerViewModel
    let workspace: Workspace
    var selectedTask: AgentTask?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            if let status = viewModel.statusMessage {
                infoBanner(status)
            }

            environmentPickerRow

            ForEach(viewModel.runtimeContractRows) { row in
                runtimeContractRow(row)
            }

            if viewModel.canSwitchPinnedTaskToWorkspaceEnvironment && !viewModel.canUseEnvironmentPicker {
                pinnedTaskEnvironmentActionRow
            }

            if viewModel.shouldShowCredentialProjectionRow {
                credentialProjectionRow
            }

            if viewModel.buildRequest != nil {
                buildActionRow
            }

            if let title = viewModel.dockerIssueTitle,
               let subtitle = viewModel.dockerIssueSubtitle {
                dockerIssueRow(title: title, subtitle: subtitle, detail: viewModel.imageInventoryIssue)
            }

            if let detected = viewModel.detectedSummary {
                detectedSummaryRow(detected)
            }
        }
    }

    // MARK: - Rows (one line per fact)

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
            rowLine(
                icon: viewModel.selectedEnvironment.isContainerized ? "shippingbox" : "desktopcomputer",
                key: viewModel.environmentPickerTitle,
                value: viewModel.selectedEnvironment.displayName
            ) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(9, weight: .semibold))
                    .foregroundStyle(viewModel.canUseEnvironmentPicker ? Color.secondary : Stanford.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canUseEnvironmentPicker)
        .help("\(viewModel.environmentPickerSubtitle)\n\(viewModel.environmentPickerHelp)")
    }

    /// `Provider: Host` reads as key and value; the contract's explanation is
    /// the tooltip.
    private func runtimeContractRow(_ contract: DockerRuntimeContractRow) -> some View {
        let parts = contract.title.components(separatedBy: ": ")
        let key = parts.count > 1 ? parts[0] : contract.title
        let value = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : nil
        return rowLine(icon: contract.iconSystemName, key: key, value: value)
            .help("\(contract.subtitle)\n\(contract.help)")
    }

    private var pinnedTaskEnvironmentActionRow: some View {
        HStack(spacing: 6) {
            rowLine(icon: "arrow.triangle.2.circlepath", key: viewModel.pinnedTaskEnvironmentActionTitle)
            Button {
                viewModel.switchPinnedTaskToWorkspaceEnvironment()
            } label: {
                Text("Switch")
                    .font(Stanford.caption(Layout.rowValueFontSize).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .help("\(viewModel.pinnedTaskEnvironmentActionSubtitle)\n\(viewModel.pinnedTaskEnvironmentActionHelp)")
    }

    private var credentialProjectionRow: some View {
        Button {
            viewModel.toggleGCPADCProjection()
        } label: {
            rowLine(icon: "key", key: viewModel.credentialProjectionTitle) {
                Image(systemName: viewModel.credentialProjectionActionSystemName)
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(viewModel.credentialProjectionIsEnabled ? Stanford.lagunita : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.credentialProjectionIsEnabled)
        .help("\(viewModel.credentialProjectionSubtitle)\n\(viewModel.credentialProjectionHelp)")
    }

    /// The image is a fact; building it is the verb beside it.
    private var buildActionRow: some View {
        HStack(spacing: 6) {
            rowLine(icon: "hammer", key: viewModel.setupActionTitle, value: viewModel.buildRequest?.image)
            if viewModel.isBuildingImage {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 6)
            } else {
                Button {
                    Task { await viewModel.buildWorkspaceImage() }
                } label: {
                    Text("Build")
                        .font(Stanford.caption(Layout.rowValueFontSize).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
        }
        .help(viewModel.setupActionHelp)
    }

    /// Docker not answering blocks every containerized run, so this is one of
    /// the two things the rail tints: the repair verb, nothing else.
    private func dockerIssueRow(title: String, subtitle: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            rowLine(icon: "exclamationmark.triangle", key: title)
            Button("Refresh") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Stanford.poppy)
            .padding(.trailing, 4)
        }
        .help(detail ?? subtitle)
    }

    private func detectedSummaryRow(_ title: String) -> some View {
        let value = title.hasPrefix("Detected ") ? String(title.dropFirst("Detected ".count)) : title
        return rowLine(icon: "shippingbox", key: "Detected", value: value)
            .help("Only loaded Docker images can run workspace commands right now.")
    }

    private func rowLine(icon: String, key: String, value: String? = nil) -> some View {
        rowLine(icon: icon, key: key, value: value) { EmptyView() }
    }

    private func rowLine<Trailing: View>(
        icon: String,
        key: String,
        value: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(Layout.leadingIconFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Layout.leadingIconFrame)

            Text(key)
                .font(Stanford.ui(Layout.rowTitleFontSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(Stanford.caption(Layout.rowValueFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            trailing()
        }
        .frame(maxWidth: .infinity, minHeight: Layout.rowHeight, alignment: .leading)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
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
