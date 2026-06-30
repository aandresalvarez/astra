import SwiftUI

/// Slice 5b: renders a "form" view's native data-entry fields. Visibility is driven by the tested
/// `WorkspaceAppFormPresentationBuilder` (which evaluates each field's safe REDCap branching against
/// the live draft). Submit is gated: a blocked form (unsupported branching) shows its reasons and
/// disables submission so it can never write to the system of record.
struct WorkspaceAppFormView: View {
    let view: WorkspaceAppViewSpec
    let submitBlockedReasons: [String]
    let onSubmit: ([String: WorkspaceAppStorageValue]) -> Void

    @State private var values: [String: WorkspaceAppStorageValue] = [:]
    @State private var showErrors = false

    private var fields: [WorkspaceAppFormFieldPresentation] {
        WorkspaceAppFormPresentationBuilder.presentation(view: view, draft: values)
    }

    private var validationErrors: [String: String] {
        WorkspaceAppFormValidation.errors(fields: fields, values: values)
    }

    private var isBlocked: Bool { !submitBlockedReasons.isEmpty }

    private func submit() {
        showErrors = true
        guard !isBlocked, validationErrors.isEmpty else { return }
        onSubmit(values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(view.title ?? view.id)
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(fields.count) fields")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if isBlocked {
                WorkspaceAppDetailNotice(
                    title: "Submit blocked — needs review",
                    message: submitBlockedReasons.joined(separator: "\n"),
                    systemImage: "exclamationmark.triangle"
                )
            }

            let errors = validationErrors
            ForEach(fields) { field in
                fieldControl(field, error: showErrors ? errors[field.name] : nil)
            }

            if showErrors && !errors.isEmpty {
                Text("Fix the highlighted fields before submitting.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
            }

            Button(action: submit) {
                Label("Submit", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBlocked)
            .help(isBlocked ? "Resolve the review issues before submitting." : "Submit this record through the declared write mode")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func fieldControl(_ field: WorkspaceAppFormFieldPresentation, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.secondary)
                if field.required {
                    Text("*").foregroundStyle(.red)
                }
            }

            switch field.fieldType {
            case "yesno":
                Toggle("", isOn: boolBinding(field.name))
                    .labelsHidden()
                    .disabled(field.readOnly)
            case "choice":
                Picker("", selection: textBinding(field.name)) {
                    Text("—").tag("")
                    ForEach(field.choices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .labelsHidden()
                .disabled(field.readOnly)
            case "multichoice":
                // One toggle per option; the stored value is a comma-joined set.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(field.choices, id: \.value) { choice in
                        Toggle(choice.label, isOn: multiChoiceBinding(field.name, option: choice.value))
                            .disabled(field.readOnly)
                            .font(Stanford.caption(12))
                    }
                }
            case "textarea":
                TextEditor(text: textBinding(field.name))
                    .frame(minHeight: 60)
                    .font(Stanford.ui(13))
                    .disabled(field.readOnly)
            default:  // text, number, date
                TextField(field.fieldType == "date" ? "YYYY-MM-DD" : "", text: textBinding(field.name))
                    .textFieldStyle(.roundedBorder)
                    .disabled(field.readOnly)
            }

            if field.readOnly, let reason = field.readOnlyReason {
                Text(reason)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.poppy)
            }
        }
    }

    // MARK: - Bindings

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { Self.string(values[name]) },
            set: { values[name] = $0.isEmpty ? .null : .text($0) }
        )
    }

    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { Self.string(values[name]) == "1" || Self.string(values[name]).lowercased() == "true" },
            set: { values[name] = .bool($0) }
        )
    }

    private func multiChoiceBinding(_ name: String, option: String) -> Binding<Bool> {
        Binding(
            get: { Self.selectedSet(values[name]).contains(option) },
            set: { isOn in
                var set = Self.selectedSet(values[name])
                if isOn { set.insert(option) } else { set.remove(option) }
                values[name] = set.isEmpty ? .null : .text(set.sorted().joined(separator: ","))
            }
        )
    }

    private static func selectedSet(_ value: WorkspaceAppStorageValue?) -> Set<String> {
        let raw = string(value)
        guard !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func string(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .text(let text): return text
        case .integer(let int): return String(int)
        case .real(let real): return String(real)
        case .bool(let bool): return bool ? "1" : "0"
        case .null, .none: return ""
        }
    }
}
