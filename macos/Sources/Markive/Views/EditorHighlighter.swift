import AppKit

/// Live Markdown syntax highlighting for the TextKit 2 editor.
///
/// Colors arrive as TextKit 2 *rendering attributes* — they never touch
/// the NSTextStorage, so highlighting cannot pollute undo, dirty the
/// document, or invalidate layout. Only color and background change;
/// fonts and sizes stay put, so text metrics never shift under the caret.
///
/// Rendering attributes are transient: the layout manager drops them
/// whenever it re-lays-out a fragment (scrolling, edits, resizing), so
/// setting them once leaves stale colors at old offsets and none at new
/// ones. Three layers keep them correct, all answering from one cached
/// span table (no reparse): eager application when a parse lands,
/// `renderingAttributesValidator` re-providing them on every layout
/// pass, and a re-apply on scroll/resize (clip-view bounds changes) as
/// a backstop for relayouts the validator isn't consulted for.
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

    /// Up to this many UTF-16 units the first highlight parses
    /// synchronously on attach — around a millisecond of main-thread
    /// work, and the document opens already colored. Larger documents
    /// take the async path and color a beat later.
    static let synchronousParseLimit = 262_144

    private weak var textView: NSTextView?
    private weak var document: MarkdownDocument?
    /// Current spans in document (event) order — an enclosing construct
    /// precedes what it contains, so applying in order lets the inner
    /// one win on overlap. Consulted by the rendering-attributes
    /// validator on every layout pass.
    private var highlights: [EditorHighlight] = []
    // nonisolated(unsafe): only written on main; deinit must read it to
    // unregister, and deinit is nonisolated.
    nonisolated(unsafe) private var storageObserver: NSObjectProtocol?
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frameObserver: NSObjectProtocol?
    private var highlightTask: Task<Void, Never>?

    deinit {
        for observer in [storageObserver, scrollObserver, frameObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// Points the highlighter at the editor's current document. Safe to
    /// call repeatedly; re-attaching re-highlights from scratch.
    func attach(textView: NSTextView, document: MarkdownDocument) {
        self.textView = textView
        self.document = document
        highlights = []
        textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
            // Layout runs on the main thread; the view never opts into
            // background layout.
            MainActor.assumeIsolated {
                self?.provideAttributes(for: fragment, in: layoutManager)
            }
        }
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
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        // Scrolling and resizing re-lay-out fragments, which drops their
        // rendering attributes. Re-apply from the cached table — cheap,
        // no reparse.
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reapply(self.highlights)
                }
            }
        }
        // The initial layout pass lands after attach and clears eagerly
        // set attributes; it also resizes the text view to fit. Repaint
        // when that resize happens so a freshly opened document colors
        // as soon as it is laid out, not on the next scroll.
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reapply(self.highlights)
            }
        }

        // Small documents parse in about a millisecond — do the first
        // highlight synchronously so the document opens colored instead
        // of colorizing a beat after it appears.
        if document.textStorage.length <= Self.synchronousParseLimit {
            highlightTask?.cancel()
            apply(MarkiveCore.highlightSpans(markdown: document.textStorage.string))
        } else {
            scheduleHighlight(afterDebounce: false)
        }
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
                  let current = self.document,
                  current === document,
                  current.buffer.revision == revision else { return }
            self.apply(highlights)
        }
    }

    private func clearHighlights() {
        apply([])
    }

    /// Swaps in a new span table, then repaints from it.
    private func apply(_ highlights: [EditorHighlight]) {
        self.highlights = highlights
        reapply(highlights)
    }

    /// Repaints the current span table: wipe every rendering attribute,
    /// then set the spans eagerly (immediate, observable) on top of the
    /// invalidation that makes the validator re-answer at draw time.
    private func reapply(_ highlights: [EditorHighlight]) {
        guard let layoutManager = textView?.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let documentRange = layoutManager.documentRange
        layoutManager.invalidateRenderingAttributes(for: documentRange)
        layoutManager.removeRenderingAttribute(.foregroundColor, for: documentRange)
        layoutManager.removeRenderingAttribute(.backgroundColor, for: documentRange)
        let origin = contentManager.documentRange.location
        for highlight in highlights {
            guard let textRange = Self.textRange(highlight.range, from: origin, in: contentManager)
            else { continue }
            for (key, value) in Self.attributes(for: highlight.kind) {
                layoutManager.addRenderingAttribute(key, value: value, for: textRange)
            }
        }
        // Rendering-attribute changes don't mark the view dirty on their
        // own — without this, new colors wait for the next incidental
        // redraw (caret blink, scroll) to appear.
        textView?.needsDisplay = true
    }

    /// The validator: colors the parts of `fragment` that overlap the
    /// current spans. Called by TextKit on every layout pass, so colors
    /// survive scrolling, edits, and resizing — attributes set outside
    /// this callback would be dropped on the next pass.
    private func provideAttributes(
        for fragment: NSTextLayoutFragment, in layoutManager: NSTextLayoutManager
    ) {
        guard !highlights.isEmpty,
              let contentManager = layoutManager.textContentManager else { return }
        let fragmentRange = fragment.rangeInElement
        let origin = contentManager.documentRange.location
        let start = contentManager.offset(from: origin, to: fragmentRange.location)
        let end = contentManager.offset(from: origin, to: fragmentRange.endLocation)

        for highlight in highlights {
            let clipped = NSIntersectionRange(
                highlight.range, NSRange(location: start, length: end - start)
            )
            guard clipped.length > 0,
                  let textRange = Self.textRange(clipped, from: origin, in: contentManager)
            else { continue }
            layoutManager.setRenderingAttributes(
                Self.attributes(for: highlight.kind), for: textRange
            )
        }
    }

    private static func textRange(
        _ range: NSRange, from origin: NSTextLocation, in contentManager: NSTextContentManager
    ) -> NSTextRange? {
        guard let start = contentManager.location(origin, offsetBy: range.location),
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
        case .codeKeyword: [.foregroundColor: .systemPink]
        case .codeString: [.foregroundColor: .systemGreen]
        case .codeComment: [.foregroundColor: .secondaryLabelColor]
        case .codeNumber: [.foregroundColor: .systemTeal]
        case .codeFunction: [.foregroundColor: .systemIndigo]
        case .codeType: [.foregroundColor: .systemBrown]
        }
    }
}
