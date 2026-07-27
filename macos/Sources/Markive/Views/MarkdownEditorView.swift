import SwiftUI

/// Markdown source editor bound to an open NSDocument. Every edit updates the
/// document's change count, which schedules autosave-in-place.
/// TextEditor is the placeholder editor; the TextKit 2 editor replaces it later.
struct MarkdownEditorView: View {
    var document: MarkdownDocument

    var body: some View {
        TextEditor(text: Binding(
            get: { document.buffer.text },
            set: { newValue in
                document.buffer.text = newValue
                document.noteEdited()
            }
        ))
        .font(.system(.body, design: .monospaced))
        .accessibilityLabel("Markdown source editor")
    }
}
