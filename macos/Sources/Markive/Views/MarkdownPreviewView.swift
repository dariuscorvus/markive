import SwiftUI
import AppKit

/// Rendered Markdown via markive-core → WKWebView. Static per selection for
/// now; live re-render on edit is the next step.
struct MarkdownPreviewView: View {
    @Bindable var model: WorkspaceModel
    var document: DocumentItem
    var text: String

    @State private var page: String?

    var body: some View {
        Group {
            if let page {
                MarkdownWebView(
                    page: page,
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
            let markdown = text
            let baseDir = document.url.deletingLastPathComponent()
            let body = await Task.detached(priority: .userInitiated) {
                MarkiveCore.renderDocument(markdown: markdown, baseDir: baseDir)
            }.value
            page = PreviewPage.page(body: body, title: document.title)
        }
        .accessibilityLabel("Markdown preview")
    }
}
