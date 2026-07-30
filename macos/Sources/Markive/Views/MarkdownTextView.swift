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
    var navigationRequest: EditorNavigationRequest?
    var completions: (String) -> [String]

    final class NativeTextView: NSTextView {
        var markiveCompletionRange: NSRange?

        override var rangeForUserCompletion: NSRange {
            markiveCompletionRange ?? super.rangeForUserCompletion
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: MarkdownDocument
        var completionProvider: (String) -> [String]
        let highlighter = EditorHighlighter()
        private var completionQuery: String?
        var lastNavigationToken: UUID?

        init(
            document: MarkdownDocument,
            completionProvider: @escaping (String) -> [String] = { _ in [] }
        ) {
            self.document = document
            self.completionProvider = completionProvider
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            document.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NativeTextView,
                  let completion = wikilinkCompletion(in: textView) else {
                completionQuery = nil
                if let textView = notification.object as? NativeTextView {
                    textView.markiveCompletionRange = nil
                }
                return
            }
            textView.markiveCompletionRange = completion.range
            guard completionQuery != completion.query else { return }
            completionQuery = completion.query
            DispatchQueue.main.async { [weak textView] in
                textView?.complete(nil)
            }
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let completionQuery else { return words }
            index?.pointee = -1
            return completionProvider(completionQuery)
        }

        private func wikilinkCompletion(in textView: NSTextView) -> (query: String, range: NSRange)? {
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location <= textView.string.utf16.count else {
                return nil
            }
            let prefix = (textView.string as NSString).substring(
                with: NSRange(location: 0, length: selection.location)
            )
            guard let marker = prefix.range(of: "[[", options: .backwards),
                  !prefix[marker.upperBound...].contains("]]"),
                  !prefix[marker.upperBound...].contains("\n") else { return nil }
            let query = String(prefix[marker.upperBound...])
            let start = (prefix[..<marker.upperBound] as Substring).utf16.count
            return (query, NSRange(location: start, length: query.utf16.count))
        }

        // MARK: - List editing

        /// Return continues list items, Tab/Shift-Tab indent and outdent
        /// them. All edits go through insertText(_:replacementRange:) so
        /// they are undoable and hit the storage observers.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleReturn(in: textView)
            case #selector(NSResponder.insertTab(_:)):
                return handleIndent(in: textView)
            case #selector(NSResponder.insertBacktab(_:)):
                return handleOutdent(in: textView)
            default:
                return false
            }
        }

        /// The caret's line, when the selection is a plain caret.
        private func caretLine(
            in textView: NSTextView
        ) -> (lineRange: NSRange, line: String, caret: Int)? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            let text = textView.string as NSString
            let lineRange = text.lineRange(for: selection)
            var line = text.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }
            return (lineRange, line, selection.location)
        }

        private func handleReturn(in textView: NSTextView) -> Bool {
            guard let (lineRange, line, caret) = caretLine(in: textView),
                  let action = MarkdownListEditing.returnAction(
                      forLine: line, caretOffset: caret - lineRange.location
                  ) else { return false }
            switch action {
            case .continueList(let prefix):
                textView.insertText("\n" + prefix, replacementRange: textView.selectedRange())
            case .endList(let markerLength):
                textView.insertText(
                    "",
                    replacementRange: NSRange(location: lineRange.location, length: markerLength)
                )
            }
            return true
        }

        private func handleIndent(in textView: NSTextView) -> Bool {
            guard let (lineRange, line, _) = caretLine(in: textView),
                  MarkdownListEditing.marker(ofLine: line) != nil else { return false }
            textView.insertText(
                MarkdownListEditing.indentUnit,
                replacementRange: NSRange(location: lineRange.location, length: 0)
            )
            return true
        }

        private func handleOutdent(in textView: NSTextView) -> Bool {
            guard let (lineRange, line, _) = caretLine(in: textView),
                  MarkdownListEditing.marker(ofLine: line) != nil else { return false }
            let length = MarkdownListEditing.outdentLength(ofLine: line)
            guard length > 0 else { return true }
            textView.insertText(
                "",
                replacementRange: NSRange(location: lineRange.location, length: length)
            )
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, completionProvider: completions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NativeTextView(usingTextLayoutManager: true)
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
        context.coordinator.completionProvider = completions
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // SwiftUI reuses the view when the selection moves to another
        // document; retarget the storage and reset the caret.
        if textView.textContentStorage?.textStorage !== document.textStorage {
            attach(to: textView, coordinator: context.coordinator)
        }
        if let request = navigationRequest,
           request.token != context.coordinator.lastNavigationToken {
            context.coordinator.lastNavigationToken = request.token
            let boundedLocation = min(request.range.location, textView.string.utf16.count)
            let boundedLength = min(
                request.range.length,
                textView.string.utf16.count - boundedLocation
            )
            let range = NSRange(location: boundedLocation, length: boundedLength)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
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
