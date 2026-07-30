import Foundation

/// Builds the HTML page around markive-core's sanitized body, and owns the
/// asset-scheme URL space the preview loads from.
enum PreviewPage {
    /// Custom scheme the preview lives on. The page itself is served at
    /// `pageURL`; absolute-path image sources and links from render_document
    /// ("/Users/…/pic.png") resolve onto the same scheme and are vended by
    /// the scheme handler after a workspace-containment check.
    static let scheme = "markive-asset"
    static let pageURL = URL(string: "\(scheme)://workspace/__preview__.html")!
    static let mermaidScriptURL = URL(string: "\(scheme)://workspace/__mermaid__.js")!

    static func page(body: String, title: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        <script src="\(mermaidScriptURL)"></script>
        <script>\(mermaidBootstrap)</script>
        <script>\(calloutBootstrap)</script>
        <script>\(mathCopyBootstrap)</script>
        </head>
        <body><article id="content" class="markdown-body">
        \(body)
        </article></body>
        </html>
        """
    }

    /// JS that swaps the rendered body in place — no navigation, so the
    /// scroll position survives live re-renders — then re-renders any
    /// Mermaid fences the new body introduced or changed.
    static func contentSwapScript(body: String) -> String? {
        guard let json = try? String(data: JSONEncoder().encode(body), encoding: .utf8) else {
            return nil
        }
        return """
        document.getElementById('content').innerHTML = \(json);
        if (window.__markiveRenderCallouts) { window.__markiveRenderCallouts(); }
        if (window.__markiveRenderMermaid) { window.__markiveRenderMermaid(); }
        """
    }

    /// The vendored Mermaid bundle (Resources/vendor/mermaid.min.js),
    /// loaded once from the app bundle and served over the asset scheme
    /// at `mermaidScriptURL` — never fetched from the network, matching
    /// the WebView's all-schemes-blocked-except-ours posture. Empty
    /// (diagrams simply don't render, fences stay plain code) if the
    /// resource is missing, which should only happen in a broken build.
    static let mermaidScript: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("MarkivePreview: mermaid.min.js not found in the app bundle")
            return ""
        }
        return script
    }()

    /// App-authored glue between the vendored library and our fenced code
    /// blocks: initializes Mermaid once per theme, finds `code.language-
    /// mermaid` blocks, and swaps each into its rendered SVG — or, on a
    /// parse error, leaves the source visible and adds an error banner.
    /// `securityLevel: 'strict'` keeps Mermaid's own DOMPurify-backed
    /// sanitization on for diagram labels and links; never loosen it.
    /// Exposed as `window.__markiveRenderMermaid` so both the initial
    /// load and later content swaps can re-run it, and re-run again on a
    /// light/dark switch so diagram themes follow the app.
    static let mermaidBootstrap = """
    (function () {
        function currentTheme() {
            return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
                ? 'dark' : 'default';
        }
        var renderId = 0;
        async function renderAll() {
            if (!window.mermaid) return;
            window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: currentTheme() });
            var blocks = document.querySelectorAll('pre > code.language-mermaid');
            for (var i = 0; i < blocks.length; i++) {
                var code = blocks[i];
                var pre = code.parentElement;
                var container = pre.parentElement.classList.contains('mermaid-block')
                    ? pre.parentElement
                    : wrapBlock(pre);
                var diagram = container.querySelector('.mermaid-diagram');
                var error = container.querySelector('.mermaid-error');
                var id = 'markive-mermaid-' + (renderId++);
                try {
                    var result = await window.mermaid.render(id, code.textContent);
                    if (!diagram) {
                        diagram = document.createElement('div');
                        diagram.className = 'mermaid-diagram';
                        container.appendChild(diagram);
                    }
                    diagram.innerHTML = result.svg;
                    if (error) error.remove();
                    pre.hidden = true;
                } catch (err) {
                    // On a parse error Mermaid leaves its offscreen render
                    // sandbox (id "d" + our id) attached to <body> instead
                    // of cleaning it up itself.
                    var leftover = document.getElementById('d' + id);
                    if (leftover) leftover.remove();
                    if (diagram) diagram.remove();
                    if (!error) {
                        error = document.createElement('div');
                        error.className = 'mermaid-error';
                        container.insertBefore(error, pre);
                    }
                    error.textContent = 'Couldn\\u2019t render this diagram: '
                        + (err && err.message ? err.message : String(err));
                    pre.hidden = false;
                }
            }
        }
        function wrapBlock(pre) {
            var wrap = document.createElement('div');
            wrap.className = 'mermaid-block';
            pre.parentElement.insertBefore(wrap, pre);
            wrap.appendChild(pre);
            return wrap;
        }
        window.__markiveRenderMermaid = renderAll;
        document.addEventListener('DOMContentLoaded', renderAll);
        if (window.matchMedia) {
            window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', renderAll);
        }
    })();
    """

    /// MathML is rendered locally by markive-core. Copying a complete math
    /// expression returns its original dollar-delimited source instead of the
    /// browser's flattened visual text.
    static let mathCopyBootstrap = """
    document.addEventListener('copy', function (event) {
        var selection = window.getSelection();
        if (!selection || selection.rangeCount !== 1) return;
        var range = selection.getRangeAt(0);
        var node = range.commonAncestorContainer;
        var element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
        var math = element && element.closest ? element.closest('.math-expression') : null;
        if (!math || !math.dataset.source) return;
        event.preventDefault();
        event.clipboardData.setData('text/plain', math.dataset.source);
    });
    """

    /// Converts sanitized blockquotes beginning with Obsidian's `[!type]`
    /// marker into semantic callouts. It only rearranges already-sanitized
    /// nodes and never evaluates note-provided HTML or script.
    static let calloutBootstrap = """
    (function () {
        function titleFor(type) {
            return type.charAt(0).toUpperCase() + type.slice(1).replace(/-/g, ' ');
        }
        function renderAll() {
            var quotes = Array.from(document.querySelectorAll('blockquote'));
            quotes.forEach(function (quote) {
                if (quote.dataset.markiveCallout === 'true') return;
                var first = quote.firstElementChild;
                if (!first) return;
                var walker = document.createTreeWalker(first, NodeFilter.SHOW_TEXT);
                var textNode = walker.nextNode();
                if (!textNode) return;
                var match = textNode.nodeValue.match(/^\\[!([^\\]]+)\\]([+-])?\\s*(.*)/);
                if (!match) return;

                var type = match[1].toLowerCase();
                var fold = match[2] || '';
                var customTitle = match[3].trim();
                textNode.nodeValue = textNode.nodeValue.slice(match[0].length);
                if (!first.textContent.trim()) first.remove();

                var callout = fold ? document.createElement('details') : document.createElement('aside');
                callout.className = 'callout callout-' + type;
                callout.dataset.callout = type;
                callout.dataset.markiveCallout = 'true';
                if (fold === '+') callout.open = true;

                var title = fold ? document.createElement('summary') : document.createElement('div');
                title.className = 'callout-title';
                title.textContent = customTitle || titleFor(type);
                callout.appendChild(title);

                var content = document.createElement('div');
                content.className = 'callout-content';
                while (quote.firstChild) content.appendChild(quote.firstChild);
                callout.appendChild(content);
                quote.replaceWith(callout);
            });
        }
        window.__markiveRenderCallouts = renderAll;
        document.addEventListener('DOMContentLoaded', renderAll);
    })();
    """

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Maps an asset request path (the URL path of a markive-asset request,
    /// which is an absolute filesystem path) to a readable file URL — only if
    /// it stays inside the workspace root. Nil denies the request.
    static func containedFileURL(requestPath: String, workspaceRoot: URL) -> URL? {
        guard !requestPath.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: requestPath).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = workspaceRoot.canonicalPath
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "avif": "image/avif"
        case "bmp": "image/bmp"
        case "tiff", "tif": "image/tiff"
        default: "application/octet-stream"
        }
    }

    /// GitHub-flavored prose on system colors; follows the system appearance
    /// via prefers-color-scheme. Kept as a string so both build paths bundle
    /// it without resource plumbing.
    static let css = """
    :root {
        color-scheme: light dark;
        --fg: #1d1d1f;
        --fg-muted: #6e6e73;
        --border: rgba(0, 0, 0, .1);
        --code-bg: rgba(0, 0, 0, .05);
        --accent: #007aff;
        --tok-keyword: #ff2d55;
        --tok-string: #34c759;
        --tok-comment: #6e6e73;
        --tok-number: #30b0c7;
        --tok-function: #5856d6;
        --tok-type: #a2845e;
        --danger: #ff3b30;
        --danger-bg: rgba(255, 59, 48, .1);
        --glass-bg-left: rgba(255, 255, 255, .5);
        --glass-bg-right: rgba(255, 255, 255, .3);
        --glass-border: rgba(0, 0, 0, .03);
        --glass-highlight: rgba(255, 255, 255, .5);
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --fg: #f5f5f7;
            --fg-muted: #98989d;
            --border: rgba(255, 255, 255, .145);
            --code-bg: rgba(255, 255, 255, .08);
            --accent: #0a84ff;
            --tok-keyword: #ff375f;
            --tok-string: #30d158;
            --tok-comment: #98989d;
            --tok-number: #40cbe0;
            --tok-function: #5e5ce6;
            --tok-type: #ac8e68;
            --danger: #ff453a;
            --danger-bg: rgba(255, 69, 58, .15);
            --glass-bg-left: rgba(255, 255, 255, .07);
            --glass-bg-right: rgba(255, 255, 255, .02);
            --glass-border: rgba(255, 255, 255, .04);
            --glass-highlight: rgba(255, 255, 255, .1);
        }
    }
    * { box-sizing: border-box; }
    body {
        margin: 0;
        color: var(--fg);
        font: 15px/1.6 -apple-system, system-ui, sans-serif;
        -webkit-text-size-adjust: 100%;
    }
    .markdown-body { padding: 2em 2.5em; max-width: 54em; }
    h1, h2, h3, h4, h5, h6 {
        margin: 1.4em 0 0.5em;
        line-height: 1.25;
        font-weight: 600;
    }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h1:first-child { margin-top: 0; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    a:focus-visible {
        outline: 2px solid var(--accent);
        outline-offset: 3px;
        border-radius: 2px;
    }
    .footnote-reference { margin-left: .08em; }
    .footnote-definition {
        display: flex;
        gap: .55em;
        align-items: baseline;
        color: var(--muted);
    }
    .footnote-definition > p { flex: 1; }
    .footnote-definition-label { color: var(--fg); }
    .footnote-backlinks { white-space: nowrap; }
    .unresolved-footnote { color: var(--danger); text-decoration: underline wavy; }
    .math-expression { font-size: 1.08em; user-select: all; }
    .math-display {
        display: block;
        margin: 1em 0;
        overflow-x: auto;
        text-align: center;
    }
    .math-error {
        color: var(--danger);
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .math-error-message { font: 12px/1.4 -apple-system, system-ui, sans-serif; }
    .broken-link { color: var(--danger); text-decoration: underline wavy; }
    .ambiguous-link { color: #ff9500; text-decoration: underline dotted; }
    p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
    code, pre {
        font: 85%/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
        border-radius: 6px;
    }
    code { padding: .2em .4em; background: var(--code-bg); }
    /* Liquid Glass approximation: WKWebView content can't use a real
       NSVisualEffectView material, so blur + saturate + a translucent
       tint + a glossy inner edge stand in for it. Shared by code fences
       and rendered Mermaid diagrams — both read as the same glass panel. */
    pre, .mermaid-diagram {
        border-radius: 12px;
        background: radial-gradient(circle at top left, var(--glass-bg-left), var(--glass-bg-right) 55%);
        backdrop-filter: blur(24px) saturate(180%);
        -webkit-backdrop-filter: blur(24px) saturate(180%);
        box-shadow: inset 0 0 0 1px var(--glass-border), inset 0 1px 0 var(--glass-highlight);
    }
    pre { padding: 1em; overflow-x: auto; }
    pre code { padding: 0; background: none; border-radius: 0; }
    .tok-keyword { color: var(--tok-keyword); }
    .tok-string { color: var(--tok-string); }
    .tok-comment { color: var(--tok-comment); }
    .tok-number { color: var(--tok-number); }
    .tok-function { color: var(--tok-function); }
    .tok-type { color: var(--tok-type); }
    .mermaid-block { margin: 0 0 1em; }
    .mermaid-block pre { margin: 0 0 .5em; }
    .mermaid-diagram { display: flex; justify-content: center; overflow-x: auto; padding: 1em; }
    .mermaid-diagram svg { max-width: 100%; height: auto; }
    .mermaid-error {
        margin: 0 0 .5em;
        padding: .6em 1em;
        border-radius: 6px;
        background: var(--danger-bg);
        color: var(--danger);
        font-size: .9em;
    }
    blockquote {
        padding: 0 1em;
        color: var(--fg-muted);
        border-left: .25em solid var(--border);
    }
    .callout {
        --callout-accent: var(--accent);
        display: block;
        margin: 0 0 1em;
        padding: .85em 1em;
        border: 1px solid color-mix(in srgb, var(--callout-accent) 35%, transparent);
        border-left: .3em solid var(--callout-accent);
        border-radius: 10px;
        background: color-mix(in srgb, var(--callout-accent) 9%, transparent);
    }
    .callout-title { color: var(--callout-accent); font-weight: 650; }
    summary.callout-title { cursor: pointer; }
    .callout-content > :first-child { margin-top: .55em; }
    .callout-content > :last-child { margin-bottom: 0; }
    .callout-warning, .callout-caution, .callout-attention { --callout-accent: #ff9500; }
    .callout-danger, .callout-error, .callout-failure, .callout-bug { --callout-accent: var(--danger); }
    .callout-success, .callout-check, .callout-done { --callout-accent: #34c759; }
    .callout-question, .callout-help, .callout-faq { --callout-accent: #af52de; }
    .callout-tip, .callout-hint, .callout-important { --callout-accent: #30b0c7; }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    th, td { padding: .4em .8em; border: 1px solid var(--border); }
    th { font-weight: 600; }
    img { max-width: 100%; }
    hr { height: 1px; border: 0; background: var(--border); margin: 1.5em 0; }
    ul.contains-task-list { list-style: none; padding-left: .5em; }
    input[type="checkbox"] { margin-right: .5em; }
    """
}
