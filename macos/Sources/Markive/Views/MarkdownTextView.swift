import SwiftUI
import AppKit

/// TextKit 2 editor attached directly to the document's NSTextStorage —
/// no string round-trip per keystroke, and every window editing the same
/// document shares the storage. Undo delegates to the document's undo
/// manager, which feeds NSDocument's automatic change counting (and
/// autosave scheduling).
///
/// TextKit 2 discipline: never touch `.layoutManager` — one access silently
/// downgrades the view to TextKit 1.
struct MarkdownTextView: NSViewRepresentable {
    let document: MarkdownDocument

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: MarkdownDocument
        let highlighter = EditorHighlighter()

        init(document: MarkdownDocument) {
            self.document = document
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            document.undoManager
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // A Markdown source editor must not "improve" punctuation.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        attach(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.document = document
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // SwiftUI reuses the view when the selection moves to another
        // document; retarget the storage and reset the caret.
        if textView.textContentStorage?.textStorage !== document.textStorage {
            attach(to: textView, coordinator: context.coordinator)
        }
    }

    private func attach(to textView: NSTextView, coordinator: Coordinator) {
        textView.textContentStorage?.textStorage = document.textStorage
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // Typing attributes don't carry over from the previous storage.
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        coordinator.highlighter.attach(textView: textView, document: document)
    }
}
