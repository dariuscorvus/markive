import SwiftUI

/// Markdown source editor — a TextKit 2 NSTextView attached to the open
/// NSDocument's text storage. Syntax highlighting arrives in the next PR.
struct MarkdownEditorView: View {
    @Bindable var model: WorkspaceModel
    var document: DocumentItem
    var openDocument: MarkdownDocument
    @State private var indexTask: Task<Void, Never>?

    var body: some View {
        MarkdownTextView(
            document: openDocument,
            navigationRequest: model.pendingEditorNavigation?.documentID == document.id
                ? model.pendingEditorNavigation : nil,
            completions: { query in
                model.store.knowledgeIndex.linkCompletions(matching: query)
            }
        )
            .accessibilityLabel("Markdown source editor")
            .onChange(of: openDocument.buffer.revision) {
                indexTask?.cancel()
                indexTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await model.store.updateIndex(
                        for: document,
                        content: openDocument.buffer.text
                    )
                }
            }
    }
}
