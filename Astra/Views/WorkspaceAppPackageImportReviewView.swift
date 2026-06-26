import SwiftUI

struct WorkspaceAppPackageImportReviewView: View {
    let review: WorkspaceAppPackageImportReview
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    trustSection
                    dependencySection
                    storageSection
                    validationSection
                }
                .padding(24)
            }

            footer
        }
        .frame(width: 720)
        .frame(minHeight: 560)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppPackageImportReviewView")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(Stanford.ui(21, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Import Workspace App")
                    .font(Stanford.heading(20))
                    .foregroundStyle(.primary)

                Text(review.packageURL.lastPathComponent)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            WorkspaceAppStatusPill(
                label: review.report.installState.rawValue,
                systemImage: review.canInstall ? "checkmark.seal" : "xmark.octagon",
                isWarning: !review.canInstall
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Stanford.cardBackground)
    }

    private var identitySection: some View {
        reviewSection("Package", count: nil) {
            infoRow("Name", review.packageName)
            infoRow("Package ID", review.packageID)
            infoRow("Version", review.version)
            infoRow("Minimum ASTRA", review.minimumASTRAVersion)
            infoRow("Permission Mode", review.permissionMode.rawValue)
            infoRow("Automations", review.automationCount == 0 ? "None" : "\(review.automationCount), disabled until enabled")
        }
    }

    @ViewBuilder
    private var trustSection: some View {
        if let trustSummary = review.trustSummary {
            reviewSection("Trust", count: nil) {
                infoRow("Signer", trustSummary.signerIdentity)
                infoRow("Source", trustSummary.trustSource)
                infoRow("Status", trustSummary.statusLabel)
                infoRow("Digest", trustSummary.packageDigest)
            }
        }
    }

    private var dependencySection: some View {
        reviewSection("Dependency Mapping", count: review.dependencyMappings.count) {
            if review.dependencyMappings.isEmpty {
                Text("No external capability dependencies.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(review.dependencyMappings) { mapping in
                    dependencyMappingRow(mapping)
                }
            }
        }
    }

    private var storageSection: some View {
        reviewSection("Storage", count: review.storageTables.count) {
            if review.storageTables.isEmpty {
                Text("No app-owned storage schema.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(review.storageTables, id: \.name) { table in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(table.name)
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(table.columns.map { "\($0.name): \($0.type)" }.joined(separator: ", "))
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var validationSection: some View {
        reviewSection("Validation", count: review.report.issues.count == 0 ? nil : review.report.issues.count) {
            if review.report.issues.isEmpty {
                WorkspaceAppDetailNotice(
                    title: "Ready to install",
                    message: "The package validates. It will install as a local draft app for review.",
                    systemImage: "checkmark.seal"
                )
            } else {
                ForEach(Array(review.report.issues.enumerated()), id: \.offset) { _, issue in
                    WorkspaceAppDetailNotice(
                        title: issue.severity.rawValue.capitalized,
                        message: "\(issue.path): \(issue.message)",
                        systemImage: issue.severity == .blocker ? "xmark.octagon" : "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)

            Button(action: onInstall) {
                Label("Install App", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!review.canInstall)
            .help(review.canInstall ? "Install this package into the workspace" : "Resolve package blockers before install")
        }
        .padding(16)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func reviewSection<Content: View>(
        _ title: String,
        count: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(value)
                .font(Stanford.caption(12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dependencyMappingRow(_ mapping: WorkspaceAppPackageDependencyMapping) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mapping.requirement.id)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)

                Text(mapping.isRequired ? "Required" : "Optional")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(mapping.isRequired && !mapping.isMapped ? Stanford.statusWarn : .secondary)

                Text(mapping.statusLabel)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(mapping.isMapped ? Stanford.paloAltoGreen : Stanford.statusWarn)
            }

            Text("\(mapping.familyName): \(mapping.operationSummary)")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !mapping.candidateImplementations.isEmpty {
                Text("Candidates: \(mapping.candidateImplementations.map { $0.provider }.joined(separator: ", "))")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
