import AppKit
import SwiftUI

struct ApplicationInstallerPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let statusTitle: String
    let statusDetail: String
    let statusSystemImageName: String
    let primaryActionTitle: String
    let footer: String

    init(plan: ApplicationInstallationPlan) {
        title = "Install \(plan.sourceMetadata.displayName)"
        message = "\(plan.sourceMetadata.displayName) will be copied to Applications and opened automatically."
        primaryActionTitle = "Install and Open \(plan.sourceMetadata.displayName)"
        footer = "Installs in Applications · Opens automatically"

        if plan.replacesExistingCopy {
            statusTitle = "Existing copy found"
            statusSystemImageName = "doc.on.doc"
            if let existingVersion = plan.existingVersion {
                statusDetail = "Version \(existingVersion) will be replaced by \(plan.sourceMetadata.version)."
            } else {
                statusDetail = "The installed copy will be replaced by version \(plan.sourceMetadata.version)."
            }
        } else {
            statusTitle = "Ready to install"
            statusSystemImageName = "folder.badge.plus"
            statusDetail = "Version \(plan.sourceMetadata.version) will be installed in Applications."
        }
    }
}

@MainActor
final class ApplicationInstallerViewModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case installing
        case completed
        case failed(String)
    }

    typealias InstallOperation = @Sendable () -> String?

    let presentation: ApplicationInstallerPresentation
    @Published private(set) var phase: Phase = .ready

    private let installOperation: InstallOperation
    private let prepareRelaunch: () throws -> Void
    private let onCompleted: () -> Void
    private let onCancel: () -> Void
    private let onFailure: (String) -> Void

    init(
        presentation: ApplicationInstallerPresentation,
        installOperation: @escaping InstallOperation,
        prepareRelaunch: @escaping () throws -> Void,
        onCompleted: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.presentation = presentation
        self.installOperation = installOperation
        self.prepareRelaunch = prepareRelaunch
        self.onCompleted = onCompleted
        self.onCancel = onCancel
        self.onFailure = onFailure
    }

    func install() {
        guard phase != .installing else { return }
        phase = .installing
        let operation = installOperation

        Task { @MainActor [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                operation()
            }.value

            guard let self else { return }
            if let failure {
                phase = .failed(failure)
                onFailure(failure)
                return
            }

            do {
                try prepareRelaunch()
            } catch {
                let message = "ASTRA was installed, but could not open automatically. \(error.localizedDescription)"
                phase = .failed(message)
                onFailure(message)
                return
            }

            phase = .completed
            try? await Task.sleep(nanoseconds: 850_000_000)
            onCompleted()
        }
    }

    func cancel() {
        guard ApplicationInstallerModalClosePolicy.allowsClose(phase: phase) else { return }
        onCancel()
    }
}

enum ApplicationInstallerModalClosePolicy {
    static func allowsClose(phase: ApplicationInstallerViewModel.Phase) -> Bool {
        phase != .installing
    }
}

struct ApplicationInstallerView: View {
    @ObservedObject var model: ApplicationInstallerViewModel
    let appIcon: NSImage

    var body: some View {
        Group {
            switch model.phase {
            case .completed:
                completionContent
            case .failed(let message):
                failureContent(message: message)
            case .ready, .installing:
                installationContent
            }
        }
        .frame(width: 720, height: 520)
        .background(Stanford.panelBackground)
    }

    private var installationContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)

            Text(model.presentation.title)
                .font(Stanford.ui(36, weight: .bold))
                .foregroundStyle(Stanford.readingText)
                .padding(.top, 20)

            Text(model.presentation.message)
                .font(Stanford.body(16))
                .foregroundStyle(Stanford.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            statusRow
                .frame(maxWidth: 360)
                .padding(.top, 16)

            Spacer(minLength: 22)

            Button(action: model.install) {
                HStack(spacing: 9) {
                    if model.phase == .installing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(model.phase == .installing ? "Installing…" : model.presentation.primaryActionTitle)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 250)
            }
            .buttonStyle(StanfordButtonStyle(color: Stanford.cardinalRed))
            .keyboardShortcut(.defaultAction)
            .disabled(model.phase == .installing)
            .accessibilityIdentifier("ApplicationInstallerPrimaryAction")

            Button("Cancel", action: model.cancel)
                .buttonStyle(.plain)
                .font(Stanford.body(15).weight(.medium))
                .foregroundStyle(Stanford.textSecondary)
                .padding(.top, 18)
                .disabled(model.phase == .installing)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ApplicationInstallerCancelAction")

            Label(model.presentation.footer, systemImage: "lock.shield")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.textTertiary)
                .padding(.top, 20)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 48)
    }

    private var statusRow: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {
                Image(systemName: model.presentation.statusSystemImageName)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Stanford.textSecondary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.primary.opacity(0.055)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.presentation.statusTitle)
                        .font(Stanford.body(15).weight(.semibold))
                        .foregroundStyle(Stanford.readingText)
                    Text(model.presentation.statusDetail)
                        .font(Stanford.body(13))
                        .foregroundStyle(Stanford.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)

            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ApplicationInstallerStatus")
    }

    private var completionContent: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Stanford.statusHealthy)
                .accessibilityHidden(true)

            Text("ASTRA is installed")
                .font(Stanford.ui(36, weight: .bold))
                .foregroundStyle(Stanford.readingText)

            Text("Opening ASTRA from Applications…")
                .font(Stanford.body(16))
                .foregroundStyle(Stanford.textSecondary)

            ProgressView()
                .controlSize(.small)
                .padding(.top, 6)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ApplicationInstallerCompletion")
    }

    private func failureContent(message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()

            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Stanford.statusError)
                .accessibilityHidden(true)

            Text("ASTRA couldn’t finish installing")
                .font(Stanford.ui(28, weight: .bold))
                .foregroundStyle(Stanford.readingText)

            Text(message)
                .font(Stanford.body(15))
                .foregroundStyle(Stanford.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Cancel", action: model.cancel)
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
                    .keyboardShortcut(.cancelAction)

                Button("Try Again", action: model.install)
                    .buttonStyle(StanfordButtonStyle(color: Stanford.cardinalRed))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 48)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ApplicationInstallerFailure")
    }
}
