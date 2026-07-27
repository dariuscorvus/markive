import AppKit
import Testing
@testable import Markive

/// End-to-end highlighting: real MarkdownDocument storage, real TextKit 2
/// NSTextView, real async parse — asserting on the layout manager's
/// rendering attributes, which is exactly what draws on screen.
@MainActor
@Suite struct EditorHighlighterTests {
    private func makeEditor(
        text: String
    ) -> (MarkdownDocument, NSTextView, EditorHighlighter, NSScrollView) {
        let document = MarkdownDocument()
        document.replaceText(text)
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textContentStorage?.textStorage = document.textStorage
        // Wrapped like the app, so the highlighter's scroll backstop is wired.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = textView
        let highlighter = EditorHighlighter()
        highlighter.attach(textView: textView, document: document)
        return (document, textView, highlighter, scrollView)
    }

    /// Rendering attributes exist only where the validator has run, so
    /// every probe forces a layout pass first — exactly what scrolling
    /// or drawing does in the app.
    private func foregroundColor(in textView: NSTextView, at location: Int) -> NSColor? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textLocation = contentManager.location(
                  contentManager.documentRange.location, offsetBy: location
              ) else { return nil }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var found: NSColor?
        layoutManager.enumerateRenderingAttributes(from: textLocation, reverse: false) {
            _, attributes, _ in
            found = attributes[.foregroundColor] as? NSColor
            return false
        }
        return found
    }

    private func waitForForegroundColor(
        in textView: NSTextView, at location: Int
    ) async -> NSColor? {
        for _ in 0..<200 {
            if let found = foregroundColor(in: textView, at: location) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Small documents must be colored the moment attach returns — no
    /// async hop, so an opened document never appears uncolored first.
    @Test func smallDocumentHighlightsSynchronouslyOnAttach() {
        let (_, textView, highlighter, scrollView) = makeEditor(text: "# Heading\n")
        _ = highlighter; _ = scrollView
        #expect(foregroundColor(in: textView, at: 0) == .systemBlue)
    }

    @Test func highlightsHeadingAfterAttach() async {
        let (_, textView, highlighter, scrollView) = makeEditor(text: "# Heading\n\nplain text\n")
        _ = highlighter; _ = scrollView
        let color = await waitForForegroundColor(in: textView, at: 0)
        #expect(color == .systemBlue)
    }

    @Test func rehighlightsAfterEdit() async {
        let (document, textView, highlighter, scrollView) = makeEditor(text: "plain\n")
        _ = highlighter; _ = scrollView
        document.replaceText("> a quote\n")
        let color = await waitForForegroundColor(in: textView, at: 0)
        #expect(color == .secondaryLabelColor)
    }

    /// The bug this design exists for: TextKit 2 drops rendering
    /// attributes whenever it re-lays-out fragments. A scroll (clip-view
    /// bounds change) must repaint them from the cached span table.
    @Test func highlightsSurviveRelayoutAfterScroll() async {
        let (_, textView, highlighter, scrollView) = makeEditor(text: "# Heading\n\nsee [a link](https://example.com)\n")
        _ = highlighter; _ = scrollView
        #expect(await waitForForegroundColor(in: textView, at: 0) == .systemBlue)

        // Drop everything the way a re-layout does…
        guard let layoutManager = textView.textLayoutManager else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: layoutManager.documentRange)
        #expect(foregroundColor(in: textView, at: 0) == nil)

        // …then scroll: the bounds-change backstop repaints synchronously.
        guard let clipView = textView.enclosingScrollView?.contentView else {
            Issue.record("editor not in a scroll view")
            return
        }
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)

        #expect(foregroundColor(in: textView, at: 0) == .systemBlue)
        let linkStart = ("# Heading\n\nsee " as NSString).length
        #expect(foregroundColor(in: textView, at: linkStart) == .linkColor)
    }

    /// Switching the same text view to another document must never show
    /// the previous document's span table.
    @Test func documentSwitchReplacesHighlights() async {
        let (_, textView, highlighter, scrollView) = makeEditor(text: "see [a link](https://example.com)\n")
        _ = scrollView
        _ = await waitForForegroundColor(in: textView, at: 4)

        let other = MarkdownDocument()
        other.replaceText("plain text with no constructs at all\n")
        textView.textContentStorage?.textStorage = other.textStorage
        highlighter.attach(textView: textView, document: other)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(foregroundColor(in: textView, at: 4) == nil)
    }

    @Test func oversizedDocumentGetsNoHighlighting() async {
        let big = String(repeating: "# H\n", count: EditorHighlighter.sizeLimit / 4 + 1)
        let (_, textView, highlighter, scrollView) = makeEditor(text: big)
        _ = highlighter; _ = scrollView
        // Give any (incorrect) highlight pass ample time to land.
        try? await Task.sleep(for: .milliseconds(300))
        var found = false
        if let layoutManager = textView.textLayoutManager {
            layoutManager.enumerateRenderingAttributes(
                from: layoutManager.documentRange.location, reverse: false
            ) { _, attributes, _ in
                if attributes[.foregroundColor] != nil { found = true }
                return false
            }
        }
        #expect(!found)
    }

    @Test func highlightingNeverTouchesStorageOrUndo() async {
        let (document, textView, highlighter, scrollView) = makeEditor(text: "# Heading\n")
        _ = highlighter; _ = scrollView
        _ = await waitForForegroundColor(in: textView, at: 0)
        // Rendering attributes must not dirty the document or register undo.
        #expect(document.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(document.undoManager?.canUndo != true)
    }
}
