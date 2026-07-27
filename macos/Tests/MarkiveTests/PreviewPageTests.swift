import Foundation
import Testing
@testable import Markive

@Suite struct PreviewPageTests {
    @Test func pageWrapsBodyWithStyleAndEscapedTitle() {
        let page = PreviewPage.page(body: "<h1>Hi</h1>", title: "A <b>\"title\"</b>")
        #expect(page.contains("<h1>Hi</h1>"))
        #expect(page.contains("<style>"))
        #expect(page.contains("A &lt;b&gt;&quot;title&quot;&lt;/b&gt;"))
        #expect(!page.contains("<title>A <b>"))
    }

    @Test func containmentAllowsInsideAndDeniesOutside() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = URL(fileURLWithPath: root.canonicalPath)

        let inside = PreviewPage.containedFileURL(
            requestPath: canonicalRoot.appendingPathComponent("Sub/pic.png").path,
            workspaceRoot: canonicalRoot
        )
        #expect(inside != nil)

        let traversal = PreviewPage.containedFileURL(
            requestPath: canonicalRoot.appendingPathComponent("Sub/../../etc/passwd").path,
            workspaceRoot: canonicalRoot
        )
        #expect(traversal == nil)

        let outside = PreviewPage.containedFileURL(
            requestPath: "/etc/passwd",
            workspaceRoot: canonicalRoot
        )
        #expect(outside == nil)

        #expect(PreviewPage.containedFileURL(requestPath: "", workspaceRoot: canonicalRoot) == nil)
    }

    @Test func contentSwapScriptEncodesBodySafely() throws {
        let script = try #require(PreviewPage.contentSwapScript(
            body: "<p>quote \" backslash \\ newline \n</p>"
        ))
        #expect(script.hasPrefix("document.getElementById('content').innerHTML = "))
        #expect(script.contains(#"quote \" backslash \\ newline \n"#))
    }

    @Test func pageLoadsTheMermaidScriptOverTheAssetScheme() {
        let page = PreviewPage.page(body: "<p>Hi</p>", title: "T")
        #expect(page.contains(#"<script src="\#(PreviewPage.mermaidScriptURL)"></script>"#))
        #expect(page.contains("__markiveRenderMermaid"))
    }

    @Test func contentSwapScriptReRendersMermaidBlocks() throws {
        let script = try #require(PreviewPage.contentSwapScript(body: "<p>Hi</p>"))
        #expect(script.contains("window.__markiveRenderMermaid()"))
    }

    @Test func vendoredMermaidBundleIsPresentAndDefinesGlobal() throws {
        // Loaded from the checked-in resource directly (not Bundle.main —
        // that only resolves inside a real .app bundle, which `swift test`
        // doesn't assemble) as a regression check that the vendored file
        // is there and shaped the way the bootstrap script expects.
        let vendored = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MarkiveTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .appendingPathComponent("Resources/vendor/mermaid.min.js")
        let script = try String(contentsOf: vendored, encoding: .utf8)
        #expect(script.contains(#"globalThis["mermaid"]"#))
        #expect(script.utf8.count > 1_000_000)
    }

    @Test func mimeTypes() {
        #expect(PreviewPage.mimeType(forExtension: "PNG") == "image/png")
        #expect(PreviewPage.mimeType(forExtension: "jpeg") == "image/jpeg")
        #expect(PreviewPage.mimeType(forExtension: "exe") == "application/octet-stream")
    }

    @Test func renderedImagePathsResolveUnderWorkspace() throws {
        // End-to-end through the FFI: a relative image source becomes an
        // absolute path that the containment check accepts.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = URL(fileURLWithPath: root.canonicalPath)

        let html = MarkiveCore.renderDocument(
            markdown: "![pic](assets/pic.png)",
            baseDir: canonicalRoot
        )
        let prefix = "src=\""
        let start = try #require(html.range(of: prefix)?.upperBound)
        let end = try #require(html[start...].firstIndex(of: "\""))
        let src = String(html[start..<end])
        #expect(src.hasPrefix("/"), "render_document should absolutize image sources, got \(src)")
        #expect(PreviewPage.containedFileURL(requestPath: src, workspaceRoot: canonicalRoot) != nil)
    }
}
