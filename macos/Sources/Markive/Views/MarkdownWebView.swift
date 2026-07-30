import SwiftUI
import WebKit

/// WKWebView wrapper for the rendered-Markdown surface — document content
/// only, never application chrome. Security posture: non-persistent store,
/// all network schemes blocked by a content rule list, every local file read
/// funneled through the asset scheme's workspace-containment check, and all
/// link activations routed out of the web view.
///
/// Switching documents loads the page fresh; body changes for the same
/// document swap `#content` via JS so the scroll position survives.
struct MarkdownWebView: NSViewRepresentable {
    var documentID: FileID
    var title: String
    /// Sanitized body HTML from markive-core.
    var body: String
    var anchor: String? = nil
    /// Current workspace root for asset containment; nil denies all reads.
    var workspaceRoot: () -> URL?
    /// A local Markdown file was clicked (absolute path inside the workspace).
    /// The final flag is true for Option-click, which opens beside the current view.
    var onOpenLocalMarkdown: (String, String?, Bool) -> Void
    /// An unresolved wikilink was clicked.
    var onCreateMissingNote: (String) -> Void = { _ in }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MarkdownWebView
        private(set) var currentPage = ""
        private var loadedDocumentID: FileID?
        private var appliedBody: String?
        private var pageReady = false
        private var appliedAnchor: String?
        private var loadTask: Task<Void, Never>?

        init(parent: MarkdownWebView) {
            self.parent = parent
        }

        func apply(to webView: WKWebView) {
            currentPage = PreviewPage.page(body: parent.body, title: parent.title)
            if loadedDocumentID != parent.documentID {
                loadedDocumentID = parent.documentID
                appliedBody = parent.body
                appliedAnchor = nil
                pageReady = false
                loadTask?.cancel()
                loadTask = Task {
                    if let rules = await NetworkBlockRules.compiled() {
                        webView.configuration.userContentController.add(rules)
                    }
                    guard !Task.isCancelled else { return }
                    // pageURL is the same constant URL for every document —
                    // without disabling the cache, WKWebView can serve a
                    // cached response for it instead of re-invoking the
                    // scheme handler, showing a previous document's content.
                    var request = URLRequest(url: PreviewPage.pageURL)
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    webView.load(request)
                }
            } else if appliedBody != parent.body {
                appliedBody = parent.body
                swapContent(in: webView)
            }
            scrollToAnchor(in: webView)
        }

        private func swapContent(in webView: WKWebView) {
            // A swap racing the initial load is applied from didFinish instead.
            guard pageReady, let script = PreviewPage.contentSwapScript(body: parent.body) else { return }
            webView.evaluateJavaScript(script)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            if appliedBody != parent.body {
                appliedBody = parent.body
            }
            swapContent(in: webView)
            scrollToAnchor(in: webView)
        }

        private func scrollToAnchor(in webView: WKWebView) {
            guard pageReady, let anchor = parent.anchor,
                  appliedAnchor != anchor,
                  let json = try? String(
                    data: JSONEncoder().encode(anchor.removingPercentEncoding ?? anchor),
                    encoding: .utf8
                  ) else { return }
            appliedAnchor = anchor
            webView.evaluateJavaScript(
                "document.getElementById(\(json))?.scrollIntoView({block:'start'});"
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            NSLog("MarkivePreview: didFail: %@", String(describing: error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            NSLog("MarkivePreview: didFailProvisional: %@", String(describing: error))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("MarkivePreview: web content process terminated")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                return decisionHandler(.cancel)
            }
            guard navigationAction.navigationType == .linkActivated else {
                // The only programmatic navigation is our own page load.
                return decisionHandler(url == PreviewPage.pageURL ? .allow : .cancel)
            }
            switch url.scheme {
            case "http", "https":
                NSWorkspace.shared.open(url)
            case PreviewPage.scheme where WorkspaceStore.markdownExtensions.contains(url.pathExtension.lowercased()):
                parent.onOpenLocalMarkdown(
                    url.path,
                    url.fragment,
                    navigationAction.modifierFlags.contains(.option)
                )
            case PreviewPage.scheme where url.fragment != nil:
                let anchor = url.fragment?.removingPercentEncoding ?? ""
                if let json = try? String(data: JSONEncoder().encode(anchor), encoding: .utf8) {
                    webView.evaluateJavaScript(
                        """
                        (function () {
                          const target = document.getElementById(\(json));
                          if (target) {
                            target.scrollIntoView({block:'start'});
                            target.focus({preventScroll:true});
                          }
                        })();
                        """
                    )
                }
            case "markive-create":
                let target = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .removingPercentEncoding ?? ""
                if !target.isEmpty {
                    parent.onCreateMissingNote(target)
                }
            default:
                break
            }
            decisionHandler(.cancel)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            AssetSchemeHandler(
                page: { [weak coordinator = context.coordinator] in coordinator?.currentPage },
                root: workspaceRoot
            ),
            forURLScheme: PreviewPage.scheme
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: webView)
    }
}

/// Serves the preview page and, after a containment check, workspace files
/// (render_document rewrites image sources to absolute paths).
@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    let page: () -> String?
    let root: () -> URL?

    init(page: @escaping () -> String?, root: @escaping () -> URL?) {
        self.page = page
        self.root = root
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            return fail(task)
        }
        if url == PreviewPage.pageURL {
            guard let html = page() else { return fail(task) }
            return respond(task, url: url, data: Data(html.utf8), mimeType: "text/html")
        }
        if url == PreviewPage.mermaidScriptURL {
            return respond(
                task, url: url, data: Data(PreviewPage.mermaidScript.utf8), mimeType: "text/javascript"
            )
        }
        guard let root = root(),
              let fileURL = PreviewPage.containedFileURL(requestPath: url.path, workspaceRoot: root),
              let data = try? Data(contentsOf: fileURL) else {
            return fail(task)
        }
        respond(task, url: url, data: data, mimeType: PreviewPage.mimeType(forExtension: fileURL.pathExtension))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        task.didReceive(URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType == "text/html" ? "utf-8" : nil
        ))
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(CocoaError(.fileReadNoSuchFile))
    }
}

/// One compiled rule list that blocks every network scheme; the preview is
/// fully local. Compiled lazily, cached on the main actor.
@MainActor
enum NetworkBlockRules {
    private static var cached: WKContentRuleList?

    private static let rules = """
    [
        {"trigger": {"url-filter": "^https?://.*"}, "action": {"type": "block"}},
        {"trigger": {"url-filter": "^wss?://.*"}, "action": {"type": "block"}},
        {"trigger": {"url-filter": "^ftp://.*"}, "action": {"type": "block"}},
        {"trigger": {"url-filter": "^file://.*"}, "action": {"type": "block"}}
    ]
    """

    static func compiled() async -> WKContentRuleList? {
        if let cached { return cached }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "markive-network-block",
            encodedContentRuleList: rules
        )
        cached = list
        return list
    }
}
