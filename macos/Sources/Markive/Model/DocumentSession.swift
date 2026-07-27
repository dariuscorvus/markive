import AppKit
import Observation

/// Cache of open NSDocuments, keyed by file identity and shared across windows —
/// two windows editing the same file edit the same document.
@MainActor
@Observable
final class DocumentSession {
    private var open: [FileID: MarkdownDocument] = [:]

    /// Throws DocumentLoadFailure. (Typed throws crashes the Swift 6.3.3
    /// compiler's IRGen when combined with @MainActor isolation here.)
    func document(for item: DocumentItem) throws -> MarkdownDocument {
        if let document = open[item.id] { return document }
        let document: MarkdownDocument
        do {
            document = try MarkdownDocument(contentsOf: item.url, ofType: MarkdownDocument.markdownType)
        } catch let error as NSError {
            switch error.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                throw DocumentLoadFailure.missing
            default:
                throw DocumentLoadFailure.unreadable
            }
        }
        NSDocumentController.shared.addDocument(document)
        open[item.id] = document
        return document
    }

    func openDocument(id: FileID) -> MarkdownDocument? {
        open[id]
    }

    /// Save (if edited) and close. Used before rename bookkeeping and app-driven closes.
    func closeSaving(id: FileID) {
        guard let document = open.removeValue(forKey: id) else { return }
        if document.hasUnautosavedChanges {
            document.save(nil)
        }
        document.close()
    }

    /// Close without saving — the file is going to the Trash.
    func closeDiscarding(id: FileID) {
        open.removeValue(forKey: id)?.close()
    }

    /// Point an open document at its new URL after a rename or move.
    func updateURL(id: FileID, to url: URL) {
        open[id]?.fileURL = url
    }

    /// Reconcile every open document with the disk. Driven by the FSEvents
    /// rescan: NSFilePresenter callbacks don't fire reliably for uncoordinated
    /// writers (a plain `echo >>` from a shell), so the watcher is the source
    /// of truth and the presenter path is only a fast path.
    func checkExternalChanges() {
        for document in open.values {
            document.checkExternalChange()
        }
    }
}
