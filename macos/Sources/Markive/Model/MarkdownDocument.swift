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
}
