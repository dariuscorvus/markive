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

    /// `document.id` updates the instant selection changes, but
    /// `openDocument` — the actual `MarkdownDocument` whose text gets
    /// rendered — is swapped in by `WorkspaceModel.loadSelectedDocument()`,
    /// called from `DocumentDetailView`'s `.onChange(of: selectedDocumentID)`.
    /// `onChange` fires as a reaction *after* the view already rendered once
    /// with the new `document.id` paired with the still-old `openDocument`,
    /// so there is one frame where they don't match. Keying `.task(id:)` on
    /// `document.id` alone means that frame's stale-paired render is the
    /// only one that ever runs — `openDocument` catching up next frame
    /// doesn't change `document.id` again, so nothing re-triggers, and the
    /// preview keeps showing the previous document's text under the new
    /// document's identity indefinitely. Including the concrete
    /// `openDocument` instance's identity in the task key closes that gap:
    /// it re-fires again once the correct document lands, even though
    /// `document.id` didn't change a second time.
    private struct RenderKey: Equatable {
        var documentID: FileID
        var openDocumentIdentity: ObjectIdentifier
        var indexRevision: Int
    }

    private var renderKey: RenderKey {
        RenderKey(
            documentID: document.id,
            openDocumentIdentity: ObjectIdentifier(openDocument),
            indexRevision: model.store.knowledgeIndexRevision
        )
    }

    var body: some View {
        Group {
            if let rendered {
                MarkdownWebView(
                    documentID: rendered.id,
                    title: rendered.title,
                    body: rendered.html,
                    anchor: model.pendingPreviewNavigation?.documentID == document.id
                        ? model.pendingPreviewNavigation?.anchor : nil,
                    workspaceRoot: { [store = model.store] in store.rootURL },
                    onOpenLocalMarkdown: { path, heading in
                        model.openDocument(atAbsolutePath: path, heading: heading)
                    },
                    onCreateMissingNote: { target in
                        model.createDocument(named: target)
                    }
                )
            } else {
                ProgressView()
            }
        }
        .task(id: renderKey) {
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
        let prepared = model.store.knowledgeIndex.renderableMarkdown(
            markdown,
            sourcePath: document.relativePath
        )
        return await Task.detached(priority: .userInitiated) {
            MarkiveCore.renderDocument(markdown: prepared, baseDir: baseDir)
        }.value
    }
}
