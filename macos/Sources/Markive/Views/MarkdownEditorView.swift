import SwiftUI

/// Placeholder for the real Markdown editor (TextKit 2 spike comes later).
/// Plain `TextEditor` on the standard content background — no glass here.
struct MarkdownEditorView: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel("Markdown source editor")
    }
}
