import SwiftUI
import AppKit

/// Rendered Markdown via markive-core → WKWebView. Re-renders live as the
/// buffer changes (debounced); the web view swaps content in place so the
/// scroll position survives.
struct MarkdownPreviewView: View {
    @Bindable var model: WorkspaceModel
    var document: DocumentItem
    var text: String

    @State private var bodyHTML: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let bodyHTML {
                MarkdownWebView(
                    documentID: document.id,
                    title: document.title,
                    body: bodyHTML,
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
            bodyHTML = await render(text)
        }
        .onChange(of: text) { _, newText in
            renderTask?.cancel()
            renderTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                bodyHTML = await render(newText)
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
