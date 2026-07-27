import SwiftUI

/// Markdown source editor — a TextKit 2 NSTextView attached to the open
/// NSDocument's text storage. Syntax highlighting arrives in the next PR.
struct MarkdownEditorView: View {
    var document: MarkdownDocument

    var body: some View {
        MarkdownTextView(document: document)
            .accessibilityLabel("Markdown source editor")
    }
}
