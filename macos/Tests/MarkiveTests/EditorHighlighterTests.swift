import AppKit
import Testing
@testable import Markive

/// End-to-end highlighting: real MarkdownDocument storage, real TextKit 2
/// NSTextView, real async parse — asserting on the layout manager's
/// rendering attributes, which is exactly what draws on screen.
@MainActor
@Suite struct EditorHighlighterTests {
    private func makeEditor(text: String) -> (MarkdownDocument, NSTextView, EditorHighlighter) {
        let document = MarkdownDocument()
        document.replaceText(text)
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textContentStorage?.textStorage = document.textStorage
        let highlighter = EditorHighlighter()
        highlighter.attach(textView: textView, document: document)
        return (document, textView, highlighter)
    }

    private func waitForForegroundColor(
        in textView: NSTextView, at location: Int
    ) async -> NSColor? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        for _ in 0..<200 {
            guard let textLocation = contentManager.location(
                contentManager.documentRange.location, offsetBy: location
            ) else { return nil }
            var found: NSColor?
            layoutManager.enumerateRenderingAttributes(from: textLocation, reverse: false) {
                _, attributes, _ in
                found = attributes[.foregroundColor] as? NSColor
                return false
            }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func highlightsHeadingAfterAttach() async {
        let (_, textView, highlighter) = makeEditor(text: "# Heading\n\nplain text\n")
        _ = highlighter
        let color = await waitForForegroundColor(in: textView, at: 0)
        #expect(color == .systemBlue)
    }

    @Test func rehighlightsAfterEdit() async {
        let (document, textView, highlighter) = makeEditor(text: "plain\n")
        _ = highlighter
        document.replaceText("> a quote\n")
        let color = await waitForForegroundColor(in: textView, at: 0)
        #expect(color == .secondaryLabelColor)
    }

    @Test func oversizedDocumentGetsNoHighlighting() async {
        let big = String(repeating: "# H\n", count: EditorHighlighter.sizeLimit / 4 + 1)
        let (_, textView, highlighter) = makeEditor(text: big)
        _ = highlighter
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
        let (document, textView, highlighter) = makeEditor(text: "# Heading\n")
        _ = highlighter
        _ = await waitForForegroundColor(in: textView, at: 0)
        // Rendering attributes must not dirty the document or register undo.
        #expect(document.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(document.undoManager?.canUndo != true)
    }
}
