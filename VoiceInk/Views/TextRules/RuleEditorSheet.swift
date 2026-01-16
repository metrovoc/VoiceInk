import SwiftUI
import SwiftData

struct RuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let rule: TextRule?
    let modelContext: ModelContext

    @State private var pattern: String
    @State private var replacement: String
    @State private var matchMode: MatchMode
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool { rule != nil }

    init(rule: TextRule? = nil, modelContext: ModelContext) {
        self.rule = rule
        self.modelContext = modelContext
        _pattern = State(initialValue: rule?.pattern ?? "")
        _replacement = State(initialValue: rule?.replacement ?? "")
        _matchMode = State(initialValue: rule?.matchMode ?? .literal)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formContent
            Divider()
            footer
        }
        .frame(width: 400)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var header: some View {
        HStack {
            Text(isEditing ? "Edit Rule" : "Add Rule")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pattern")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("Text to match", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Replacement (empty = delete)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Match Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $matchMode) {
                    ForEach(MatchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(matchModeDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var matchModeDescription: String {
        switch matchMode {
        case .literal:
            return "Matches exact text anywhere (works for punctuation like \"...\")"
        case .regex:
            return "Matches using regular expression pattern (use \\b for word boundaries)"
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(isEditing ? "Save" : "Add") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.isEmpty)
        }
        .padding()
    }

    private func save() {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else {
            errorMessage = "Pattern cannot be empty"
            showError = true
            return
        }

        if matchMode == .regex {
            if (try? NSRegularExpression(pattern: trimmedPattern)) == nil {
                errorMessage = "Invalid regex pattern"
                showError = true
                return
            }
        }

        if let existingRule = rule {
            existingRule.pattern = trimmedPattern
            existingRule.replacement = replacement
            existingRule.matchMode = matchMode
        } else {
            let newRule = TextRule(
                pattern: trimmedPattern,
                replacement: replacement,
                matchMode: matchMode
            )
            modelContext.insert(newRule)
        }

        try? modelContext.save()
        dismiss()
    }
}
