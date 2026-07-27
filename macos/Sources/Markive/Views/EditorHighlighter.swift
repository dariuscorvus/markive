import AppKit

/// Live Markdown syntax highlighting for the TextKit 2 editor.
///
/// Colors arrive as TextKit 2 *rendering attributes* on the layout
/// manager — they never touch the NSTextStorage, so highlighting cannot
/// pollute undo, dirty the document, or invalidate layout. Only color
/// and background change; fonts and sizes stay put, so text metrics
/// never shift under the caret.
///
/// Cadence: storage edits debounce ~100 ms, the parse runs off the main
/// thread, and a result is discarded if the text changed while it was
/// in flight (the pending edit re-triggers anyway).
@MainActor
final class EditorHighlighter {
    /// Documents beyond this many UTF-16 units keep a plain editor —
    /// full-document re-parse and attribute application stop being
    /// keystroke-invisible around here.
    static let sizeLimit = 2_000_000

    private weak var textView: NSTextView?
    private weak var document: MarkdownDocument?
    // nonisolated(unsafe): only written on main; deinit must read it to
    // unregister, and deinit is nonisolated.
    nonisolated(unsafe) private var storageObserver: NSObjectProtocol?
    private var highlightTask: Task<Void, Never>?

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    /// Points the highlighter at the editor's current document. Safe to
    /// call repeatedly; re-attaching re-highlights from scratch.
    func attach(textView: NSTextView, document: MarkdownDocument) {
        self.textView = textView
        self.document = document
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: document.textStorage,
            queue: nil
        ) { [weak self] notification in
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            // The notification fires on the mutating thread — main, per
            // the document's threading contract.
            MainActor.assumeIsolated {
                self?.scheduleHighlight(afterDebounce: true)
            }
        }
        scheduleHighlight(afterDebounce: false)
    }

    private func scheduleHighlight(afterDebounce: Bool) {
        highlightTask?.cancel()
        guard let document else { return }

        if document.textStorage.length > Self.sizeLimit {
            clearHighlights()
            return
        }

        let markdown = document.textStorage.string
        let revision = document.buffer.revision
        highlightTask = Task { [weak self] in
            if afterDebounce {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            let highlights = await Task.detached(priority: .userInitiated) {
                MarkiveCore.highlightSpans(markdown: markdown)
            }.value
            guard !Task.isCancelled,
                  let self,
                  let document = self.document,
                  document.buffer.revision == revision else { return }
            self.apply(highlights)
        }
    }

    private func clearHighlights() {
        guard let layoutManager = textView?.textLayoutManager else { return }
        let documentRange = layoutManager.documentRange
        layoutManager.removeRenderingAttribute(.foregroundColor, for: documentRange)
        layoutManager.removeRenderingAttribute(.backgroundColor, for: documentRange)
    }

    private func apply(_ highlights: [EditorHighlight]) {
        guard let layoutManager = textView?.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        clearHighlights()
        // Spans arrive outermost-first; applying in order lets the
        // innermost construct win where they overlap.
        for highlight in highlights {
            guard let textRange = Self.textRange(highlight.range, in: contentManager) else {
                continue
            }
            for (key, value) in Self.attributes(for: highlight.kind) {
                layoutManager.addRenderingAttribute(key, value: value, for: textRange)
            }
        }
    }

    private static func textRange(
        _ range: NSRange, in contentManager: NSTextContentManager
    ) -> NSTextRange? {
        guard let start = contentManager.location(
                contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Semantic system colors only — they adapt to light/dark and any
    /// future accessibility contrast setting for free.
    private static func attributes(
        for kind: EditorHighlight.Kind
    ) -> [NSAttributedString.Key: NSColor] {
        switch kind {
        case .heading: [.foregroundColor: .systemBlue]
        case .emphasis: [.foregroundColor: .systemPurple]
        case .strong: [.foregroundColor: .systemOrange]
        case .codeSpan, .codeBlock: [.backgroundColor: .quaternarySystemFill]
        case .link: [.foregroundColor: .linkColor]
        case .listMarker: [.foregroundColor: .controlAccentColor]
        case .blockquote: [.foregroundColor: .secondaryLabelColor]
        }
    }
}
