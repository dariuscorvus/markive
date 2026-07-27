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

    static func page(body: String, title: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body><article id="content" class="markdown-body">
        \(body)
        </article></body>
        </html>
        """
    }

    /// JS that swaps the rendered body in place — no navigation, so the
    /// scroll position survives live re-renders.
    static func contentSwapScript(body: String) -> String? {
        guard let json = try? String(data: JSONEncoder().encode(body), encoding: .utf8) else {
            return nil
        }
        return "document.getElementById('content').innerHTML = \(json);"
    }

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
        --fg: #1f2328;
        --fg-muted: #59636e;
        --border: #d1d9e0;
        --code-bg: #f6f8fa;
        --accent: #0969da;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --fg: #f0f6fc;
            --fg-muted: #9198a1;
            --border: #3d444d;
            --code-bg: #151b23;
            --accent: #4493f8;
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
    p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
    code, pre {
        font: 85%/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
        background: var(--code-bg);
        border-radius: 6px;
    }
    code { padding: .2em .4em; }
    pre { padding: 1em; overflow-x: auto; }
    pre code { padding: 0; background: none; }
    blockquote {
        padding: 0 1em;
        color: var(--fg-muted);
        border-left: .25em solid var(--border);
    }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    th, td { padding: .4em .8em; border: 1px solid var(--border); }
    th { font-weight: 600; }
    img { max-width: 100%; }
    hr { height: 1px; border: 0; background: var(--border); margin: 1.5em 0; }
    ul.contains-task-list { list-style: none; padding-left: .5em; }
    input[type="checkbox"] { margin-right: .5em; }
    """
}
