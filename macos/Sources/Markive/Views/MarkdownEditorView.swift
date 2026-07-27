import SwiftUI

/// Read-only Markdown source view. Becomes an editable NSDocument-backed
/// editor in the editing layer — read-only here so nothing pretends to save.
struct MarkdownEditorView: View {
    var text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(.background)
        .accessibilityLabel("Markdown source")
    }
}
