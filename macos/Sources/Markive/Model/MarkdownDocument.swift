import AppKit
import Observation

/// One open Markdown file. NSDocument supplies the native document lifecycle:
/// autosave in place, the system "ask to keep changes" close behavior, change
/// counting, and quit-time saving via NSDocumentController — none of it
/// reimplemented here.
///
/// The text lives in an NSTextStorage that editor views attach to directly —
/// two windows editing the same document share the storage. Undo registers on
/// the document's undo manager (the editor delegates to it), which also feeds
/// NSDocument's automatic change counting: undoing back to the saved state
/// reads as not-dirty.
final class MarkdownDocument: NSDocument {
    /// SwiftUI-observable face of the document. `nonisolated` opts out of
    /// @Observable's inferred @MainActor so NSDocument's nonisolated
    /// read/write callbacks can reach it — everything still runs on main,
    /// since the document does not enable asynchronous saving.
    @Observable
    nonisolated final class Buffer {
        /// Bumped on every character edit; reading `text` tracks it, so views
        /// observing `text` invalidate on edits without the document copying
        /// the string per keystroke.
        fileprivate(set) var revision = 0
        /// The file changed on disk while local edits are unsaved; the UI
        /// offers Reload / Keep My Version.
        var hasConflict = false
        fileprivate weak var document: MarkdownDocument?

        var text: String {
            _ = revision
            guard let document else { return "" }
            return document.textStorage.string
        }
    }

    // Main-thread-confined by the no-async-saving contract. Buffer's
    // @unchecked Sendable exists only so the storage-edit notification
    // closure may capture it.
    nonisolated(unsafe) let textStorage = NSTextStorage()
    let buffer = Buffer()
    nonisolated(unsafe) private var storageObserver: NSObjectProtocol?
    /// Set around disk-driven storage replacement (open, revert) so those
    /// edits don't mark the document dirty.
    nonisolated(unsafe) private var isReloadingFromDisk = false

    static let markdownType = "net.daringfireball.markdown"

    override class var autosavesInPlace: Bool { true }

    override init() {
        super.init()
        buffer.document = self
        // NSTextStorage.didProcessEditingNotification fires after every edit,
        // view-driven or programmatic, on the mutating thread (main here).
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            self.buffer.revision += 1
            // Change-count safety net: typing counts via undo registration,
            // but storage mutations that bypass undo (accessibility writes,
            // programmatic edits) must still schedule autosave. Harmlessly
            // approximate — with autosave-in-place, an over-counted dirty
            // state never surfaces to the user.
            guard !self.isReloadingFromDisk else { return }
            MainActor.assumeIsolated {
                if !self.hasUnautosavedChanges {
                    self.updateChangeCount(.changeDone)
                }
            }
        }
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // Direct storage replacement: registers no undo (opens and reverts
        // must not be undoable) and must not mark the document dirty.
        isReloadingFromDisk = true
        defer { isReloadingFromDisk = false }
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: text
        )
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(textStorage.string.utf8)
    }

    /// Programmatic whole-text replacement (model operations, tests). The
    /// storage-edit observer handles change counting.
    func replaceText(_ text: String) {
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: text
        )
    }

    // MARK: - External changes

    /// NSDocument registers itself as the file's NSFilePresenter; this fires
    /// (on the presenter queue) when another process touches the file.
    override nonisolated func presentedItemDidChange() {
        Task { @MainActor in self.checkExternalChange() }
    }

    /// Clean documents reload silently; dirty ones flag a conflict for the UI.
    /// Our own autosaves don't trip this — their date matches fileModificationDate.
    func checkExternalChange() {
        guard let url = fileURL,
              let diskDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let knownDate = fileModificationDate,
              diskDate > knownDate else { return }
        if hasUnautosavedChanges {
            buffer.hasConflict = true
        } else {
            try? revert(toContentsOf: url, ofType: fileType ?? Self.markdownType)
        }
    }

    func resolveConflictReloading() {
        buffer.hasConflict = false
        if let url = fileURL {
            try? revert(toContentsOf: url, ofType: fileType ?? Self.markdownType)
        }
    }

    func resolveConflictKeepingLocal() {
        buffer.hasConflict = false
        // Acknowledge the disk version so saving doesn't raise the
        // "changed by another application" alert, then overwrite it.
        if let url = fileURL,
           let diskDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
            fileModificationDate = diskDate
        }
        save(nil)
    }
}

extension MarkdownDocument.Buffer: @unchecked Sendable {}
