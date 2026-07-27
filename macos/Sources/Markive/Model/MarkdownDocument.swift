import AppKit
import Observation

/// One open Markdown file. NSDocument supplies the native document lifecycle:
/// autosave in place, the system "ask to keep changes" close behavior, change
/// counting, and quit-time saving via NSDocumentController — none of it
/// reimplemented here.
final class MarkdownDocument: NSDocument {
    /// SwiftUI-observable text buffer. `nonisolated` opts out of @Observable's
    /// inferred @MainActor so NSDocument's nonisolated read/write callbacks can
    /// reach it — everything still runs on main, since the document does not
    /// enable asynchronous saving. The property is nonisolated(unsafe) for the
    /// same reason: NSDocument is @MainActor in the macOS 26 SDK, but
    /// read(from:)/data(ofType:) are nonisolated.
    @Observable
    nonisolated final class Buffer {
        var text = ""
        /// The file changed on disk while local edits are unsaved; the UI
        /// offers Reload / Keep My Version.
        var hasConflict = false
    }

    nonisolated(unsafe) let buffer = Buffer()

    static let markdownType = "net.daringfireball.markdown"

    override class var autosavesInPlace: Bool { true }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        buffer.text = text
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(buffer.text.utf8)
    }

    /// Called from the editor binding on every edit; schedules autosave.
    func noteEdited() {
        updateChangeCount(.changeDone)
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
