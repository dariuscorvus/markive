import SwiftUI
import AppKit

/// Rendered Markdown via markive-core → WKWebView. Re-renders live as the
/// buffer changes (debounced); the web view swaps content in place so the
/// scroll position survives. Observes the buffer's revision counter, not the
/// text — the string is only copied when a render actually runs.
struct MarkdownPreviewView: View {
    @Bindable var model: WorkspaceModel
    var document: DocumentItem
    var openDocument: MarkdownDocument

    /// The (id, title, HTML) of the last completed render, held together so
    /// MarkdownWebView never sees a documentID from one document paired
    /// with body HTML from another. `document.id` updates the instant the
    /// selection changes, but rendering is async — without this pairing,
    /// switching documents would briefly hand MarkdownWebView the new id
    /// with the previous document's stale HTML, which it would then load
    /// as if it were the new document's real content. Holding the old pair
    /// until the new one is fully ready also avoids a ProgressView flash
    /// on every switch.
    @State private var rendered: (id: FileID, title: String, html: String)?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let rendered {
                MarkdownWebView(
                    documentID: rendered.id,
                    title: rendered.title,
                    body: rendered.html,
                    workspaceRoot: { [store = model.store] in store.rootURL },
                    onOpenLocalMarkdown: { path in
                        model.openDocument(atAbsolutePath: path)
                    }
                )
            } else {
                ProgressView()
            }
        }
        .task(id: document.id) {
            let html = await render(openDocument.buffer.text)
            // Cancellation is cooperative: switching documents again while
            // this render is in flight cancels this task, but render()
            // keeps running regardless and would otherwise still land here
            // and overwrite `rendered` with this now-superseded document's
            // content — whichever render happened to finish last would win,
            // not whichever document is actually selected.
            guard !Task.isCancelled else { return }
            rendered = (document.id, document.title, html)
        }
        .onChange(of: openDocument.buffer.revision) {
            renderTask?.cancel()
            renderTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let html = await render(openDocument.buffer.text)
                guard !Task.isCancelled else { return }
                rendered = (document.id, document.title, html)
            }
        }
        .accessibilityLabel("Markdown preview")
    }

    private func render(_ markdown: String) async -> String {
        let baseDir = document.url.deletingLastPathComponent()
        return await Task.detached(priority: .userInitiated) {
            MarkiveCore.renderDocument(markdown: markdown, baseDir: baseDir)
        }.value
    }
}
