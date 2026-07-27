import Foundation
import CMarkiveFFI

/// Swift face of the markive-core Rust pipeline (crates/markive-ffi).
enum MarkiveCore {
    /// Markdown → sanitized HTML. Pure and thread-safe; call it off the main
    /// thread for large documents — the 20 MB fixture budget is enforced in
    /// MarkiveCoreTests.
    nonisolated static func renderDocument(markdown: String, baseDir: URL?) -> String {
        let html: UnsafeMutablePointer<CChar>? = markdown.withCString { markdownC in
            if let base = baseDir?.path {
                base.withCString { baseC in
                    mk_render_document(markdownC, baseC)
                }
            } else {
                mk_render_document(markdownC, nil)
            }
        }
        guard let html else { return "" }
        defer { mk_string_free(html) }
        return String(cString: html)
    }
}
