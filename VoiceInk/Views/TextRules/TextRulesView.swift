import SwiftUI
import SwiftData

struct TextRulesView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CompactHeroSection(
                    icon: "doc.text.magnifyingglass",
                    title: "Text Transform",
                    description: "Apply text transformations after transcription for cleanup and formatting",
                    maxDescriptionWidth: 500
                )

                TextRulesContentView()
                    .padding(.horizontal, 32)
                    .padding(.vertical, 40)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct TextRulesContentView: View {
    @Query(sort: \TextRule.dateAdded) private var rules: [TextRule]
    @Environment(\.modelContext) private var modelContext
    @State private var editingRule: TextRule?
    @State private var showAddSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showInfoPopover = false
    @State private var previewExpanded = false
    @State private var previewInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                Label {
                    Text("Transform rules apply after transcription. Use for punctuation cleanup, deletions, or regex patterns.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Button(action: { showInfoPopover.toggle() }) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showInfoPopover) {
                        TextRulesInfoPopover()
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            }

            if !rules.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Pattern")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Mode")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 80)

                        Text("Replacement")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rules) { rule in
                                RuleRow(
                                    rule: rule,
                                    onEdit: { editingRule = rule },
                                    onDelete: { deleteRule(rule) },
                                    onToggle: { toggleRule(rule) }
                                )

                                if rule.id != rules.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                .background(CardBackground(isSelected: false))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No transform rules yet")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(CardBackground(isSelected: false))
            }

            // Preview section
            if !rules.isEmpty {
                PreviewSection(
                    isExpanded: $previewExpanded,
                    input: $previewInput,
                    rules: rules
                )
            }
        }
        .sheet(isPresented: $showAddSheet) {
            RuleEditorSheet(modelContext: modelContext)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(rule: rule, modelContext: modelContext)
        }
        .alert("Text Transform", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func deleteRule(_ rule: TextRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }

    private func toggleRule(_ rule: TextRule) {
        rule.isEnabled.toggle()
        try? modelContext.save()
    }
}

struct TextRulesInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pattern Examples")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                patternExample(
                    mode: "Literal",
                    pattern: "...",
                    replacement: "",
                    description: "Delete ellipsis (works for any punctuation)"
                )

                patternExample(
                    mode: "Literal",
                    pattern: " ,",
                    replacement: ",",
                    description: "Fix space before comma"
                )

                Divider()

                patternExample(
                    mode: "Regex",
                    pattern: "\\b(um|uh)\\b",
                    replacement: "",
                    description: "Delete filler words (\\b = word boundary)"
                )

                patternExample(
                    mode: "Regex",
                    pattern: "\\bdont\\b",
                    replacement: "don't",
                    description: "Fix missing apostrophe (whole word only)"
                )

                patternExample(
                    mode: "Regex",
                    pattern: "\\s{2,}",
                    replacement: " ",
                    description: "Collapse multiple spaces"
                )

                patternExample(
                    mode: "Regex",
                    pattern: "^\\s+|\\s+$",
                    replacement: "",
                    description: "Trim leading/trailing whitespace"
                )
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func patternExample(mode: String, pattern: String, replacement: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(mode)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(4)

                Text(pattern)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(replacement.isEmpty ? "(delete)" : replacement)
                    .font(.system(size: 12, design: replacement.isEmpty ? .default : .monospaced))
                    .italic(replacement.isEmpty)
                    .foregroundColor(replacement.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview Section

struct PreviewSection: View {
    @Binding var isExpanded: Bool
    @Binding var input: String
    let rules: [TextRule]

    private var previewResult: (steps: [RulePreviewStep], final: String) {
        TextTransformService.preview(input: input, rules: rules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Text("Preview")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Input field
                    TextField("Enter test text...", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))

                    // Results
                    if !input.isEmpty {
                        previewResultsView
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var previewResultsView: some View {
        let result = previewResult

        VStack(alignment: .leading, spacing: 0) {
            // Pipeline steps
            ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    // Change indicator
                    Image(systemName: step.changed ? "arrow.right.circle.fill" : "arrow.right.circle")
                        .font(.system(size: 11))
                        .foregroundColor(step.changed ? .accentColor : .secondary.opacity(0.5))

                    // Rule pattern
                    Text(step.rule.pattern)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(step.changed ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer()

                    // Output after this rule
                    Text(step.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(step.changed ? .primary : .secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(step.changed ? Color.accentColor.opacity(0.08) : Color.clear)

                if index < result.steps.count - 1 {
                    Divider().padding(.leading, 28)
                }
            }

            // Final result
            if !result.steps.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("Result")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(result.final)
                        .font(.system(size: 12, design: .monospaced))
                        .fontWeight(.medium)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
        }
        .background(Color(.textBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}
