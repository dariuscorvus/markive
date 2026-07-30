import Testing
import WebKit
@testable import Markive

/// End-to-end through a real (off-screen, never shown) WKWebView, driving
/// the actual `MarkdownWebView.Coordinator.apply(to:)` — not a stand-in.
/// Guards against a WKWebView quirk that caused stale content after
/// switching documents: the preview page always loads from the same
/// constant `pageURL`, and without disabling the cache WKWebView can serve
/// a cached response for that URL instead of re-invoking the scheme
/// handler.
@MainActor
@Suite struct MarkdownWebViewSchemeTests {
    private func webView(id: FileID, title: String, body: String) -> MarkdownWebView {
        MarkdownWebView(
            documentID: id,
            title: title,
            body: body,
            workspaceRoot: { nil },
            onOpenLocalMarkdown: { _, _, _ in }
        )
    }

    /// Mirrors what `makeNSView` sets up, minus the parts of `Context`
    /// that aren't constructible outside SwiftUI's own hosting — the
    /// scheme handler and coordinator wiring is what matters here.
    private func makeHostedWebView(coordinator: MarkdownWebView.Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            AssetSchemeHandler(page: { [weak coordinator] in coordinator?.currentPage }, root: { nil }),
            forURLScheme: PreviewPage.scheme
        )
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }

    /// `textContent`, not `innerText` — innerText depends on layout having
    /// run, which an off-screen, never-displayed WKWebView may skip.
    private func waitForContent(_ webView: WKWebView, containing marker: String) async -> Bool {
        for _ in 0..<300 {
            if let text = try? await webView.evaluateJavaScript("document.body.textContent") as? String,
               text.contains(marker) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func switchingDocumentsServesFreshContentThroughTheRealCoordinator() async {
        let docA = FileID(device: 1, inode: 1)
        let docB = FileID(device: 1, inode: 2)

        let parentA = webView(id: docA, title: "A", body: "MARKER-DOC-A")
        let coordinator = parentA.makeCoordinator()
        let hosted = makeHostedWebView(coordinator: coordinator)

        coordinator.apply(to: hosted)
        #expect(await waitForContent(hosted, containing: "MARKER-DOC-A"))

        coordinator.parent = webView(id: docB, title: "B", body: "MARKER-DOC-B")
        coordinator.apply(to: hosted)
        #expect(await waitForContent(hosted, containing: "MARKER-DOC-B"))

        // The real failure mode: the second load silently keeps showing
        // the first document's content because WKWebView served a cached
        // response for the identical pageURL instead of asking the scheme
        // handler again.
        let text = try? await hosted.evaluateJavaScript("document.body.textContent") as? String
        #expect(text?.contains("MARKER-DOC-A") == false)
    }

    @Test func manySuccessiveSwitchesEachServeTheirOwnContent() async {
        let ids = (0...5).map { FileID(device: 1, inode: $0) }
        let parent0 = webView(id: ids[0], title: "0", body: "MARKER-0")
        let coordinator = parent0.makeCoordinator()
        let hosted = makeHostedWebView(coordinator: coordinator)

        coordinator.apply(to: hosted)
        #expect(await waitForContent(hosted, containing: "MARKER-0"))

        for index in 1...5 {
            coordinator.parent = webView(id: ids[index], title: "\(index)", body: "MARKER-\(index)")
            coordinator.apply(to: hosted)
            #expect(await waitForContent(hosted, containing: "MARKER-\(index)"))
        }
    }
}
