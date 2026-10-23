import AppKit
import SwiftUI
import ASTRACore

/// Review of a plugin file before it is imported: what it is, and what
/// blocks or warns about it. Moved from the retired catalog view.
struct CapabilityImportReview: Identifiable {
    let id = UUID()
    let report: CapabilityPackageValidationReport

    var sourceURL: URL? {
        report.sourceURL
    }
}


struct CapabilityImportReviewSheet: View {
    let review: CapabilityImportReview
    let onCancel: () -> Void
    let onImport: (CapabilityPackageValidationReport) -> Void

    private var report: CapabilityPackageValidationReport {
        review.report
    }

    private var package: PluginPackage? {
        report.package
    }

    var body: some View {
        let iconPresentation = package.map(CapabilityIconPresentation.make)
            ?? CapabilityIconPresentation.make(name: "Invalid Capability", fallbackSystemName: "exclamationmark.triangle")

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CapabilityIconView(
                    presentation: iconPresentation,
                    size: 18,
                    color: report.canInstall ? Stanford.lagunita : Stanford.poppy,
                    weight: .semibold
                )
                    .frame(width: 34, height: 34)
                    .background((report.canInstall ? Stanford.lagunita : Stanford.poppy).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(package?.name ?? "Invalid Capability")
                        .font(Stanford.heading(18))
                    Text(review.sourceURL?.lastPathComponent ?? "Package JSON")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let package {
                        importPackageOverview(package)
                    }
                    importIssueSection(
                        title: "Blockers",
                        empty: "No blockers",
                        issues: report.blockers,
                        color: Stanford.cardinalRed,
                        icon: "xmark.octagon.fill"
                    )
                    importIssueSection(
                        title: "Warnings",
                        empty: "No warnings",
                        issues: report.warnings,
                        color: Stanford.poppy,
                        icon: "exclamationmark.triangle.fill"
                    )
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onImport(report)
                } label: {
                    Label("Import Capability", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .disabled(!report.canInstall)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 640, height: 560)
    }

    private func importPackageOverview(_ package: PluginPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.id)
                        .font(Stanford.ui(12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(CapabilityImportPresentation.overviewDescription(
                        for: package,
                        contentSummary: importContentSummary(package)
                    ))
                        .font(Stanford.body(13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                importChip("v\(package.version)", color: Stanford.coolGrey)
                importChip(package.governance.approvalStatus.rawValue.capitalized, color: Stanford.poppy)
            }

            if CapabilityImportPresentation.shouldShowContentSummary(for: package) {
                Text(importContentSummary(package))
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func importIssueSection(
        title: String,
        empty: String,
        issues: [CapabilityPackageValidationIssue],
        color: Color,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(color)
                Text("\(issues.count)")
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.08))
                    .clipShape(Capsule())
                Spacer()
            }

            if issues.isEmpty {
                Text(empty)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(Stanford.caption(11).weight(.semibold))
                            Text(issue.message)
                                .font(Stanford.caption(10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    private func importChip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(Stanford.caption(10).weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.08))
            .clipShape(Capsule())
    }

    private func importContentSummary(_ package: PluginPackage) -> String {
        let parts = [
            countPhrase(package.skills.count, singular: "skill", plural: "skills"),
            countPhrase(package.connectors.count, singular: "connector", plural: "connectors"),
            countPhrase(package.localTools.count, singular: "tool", plural: "tools"),
            countPhrase(package.mcpServers.count, singular: "MCP server", plural: "MCP servers"),
            countPhrase(package.browserAdapters.count, singular: "browser adapter", plural: "browser adapters"),
            countPhrase(package.templates.count, singular: "template", plural: "templates")
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? "No installable payload" : parts.joined(separator: ", ")
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        guard count > 0 else { return "" }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}

// MARK: - Install Setup Sheet
