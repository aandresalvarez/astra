import SwiftUI
import ASTRACore
import ASTRAModels

struct SpecCardView: View {
    @Binding var spec: TaskSpec?
    @Binding var chainedGoal: String
    let onCreateTask: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if var spec = spec {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Task Spec")
                        .font(Stanford.ui(15, weight: .semibold))
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let clarifications = spec.clarifications, !clarifications.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Clarifications needed:", systemImage: "questionmark.circle")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.poppy)
                        ForEach(clarifications, id: \.self) { q in
                            Text("\u{2022} \(q)")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(8)
                    .background(Stanford.poppy.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Group {
                    EditableField(label: "Title", text: Binding(
                        get: { spec.title },
                        set: { spec.title = $0; self.spec = spec }
                    ))

                    EditableField(label: "Goal", text: Binding(
                        get: { spec.goal },
                        set: { spec.goal = $0; self.spec = spec }
                    ), axis: .vertical)

                    HStack {
                        Label("Complexity", systemImage: "gauge.medium")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                        Text(spec.estimatedComplexity)
                            .font(Stanford.caption(12))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary)
                            .clipShape(Capsule())
                    }

                    EditableListField(label: "Constraints", items: Binding(
                        get: { spec.constraints },
                        set: { spec.constraints = $0; self.spec = spec }
                    ))

                    EditableListField(label: "Acceptance Criteria", items: Binding(
                        get: { spec.acceptanceCriteria },
                        set: { spec.acceptanceCriteria = $0; self.spec = spec }
                    ))
                }

                // Chain: follow-up task
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(Stanford.ui(12))
                            .foregroundStyle(.secondary)
                        Text("Then do... (optional)")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                    TextField("Describe what should happen after this task completes", text: $chainedGoal, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(Stanford.caption(12))
                        .lineLimit(1...3)
                }

                HStack {
                    Spacer()
                    Button("Create Task", action: onCreateTask)
                        .buttonStyle(StanfordButtonStyle())
                        .disabled(spec.title.isEmpty || spec.goal.isEmpty)
                }
            }
            .padding()
            .background(Stanford.fog)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Stanford.cardinalRed.opacity(Stanford.strokeActive), lineWidth: 1)
            )
        }
    }
}

struct EditableField: View {
    let label: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            TextField(label, text: $text, axis: axis == .vertical ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.body(15))
                .lineLimit(axis == .vertical ? 2...4 : 1...1)
        }
    }
}

struct EditableListField: View {
    let label: String
    @Binding var items: [String]
    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    TextField(label, text: Binding(
                        get: { index < items.count ? items[index] : "" },
                        set: { if index < items.count { items[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.caption(12))
                    Button {
                        if index < items.count { items.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(Stanford.caption(12))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 4) {
                TextField("Add \(label.lowercased())...", text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.caption(12))
                    .onSubmit {
                        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            items.append(trimmed)
                            newItem = ""
                        }
                    }
                Button {
                    let trimmed = newItem.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        items.append(trimmed)
                        newItem = ""
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Stanford.interactive)
                        .font(Stanford.caption(12))
                }
                .buttonStyle(.plain)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
