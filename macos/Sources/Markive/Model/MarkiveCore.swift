import Foundation
import CMarkiveFFI

/// One editor highlight: an NSRange (UTF-16, ready for TextKit) and what
/// the range is.
struct EditorHighlight: Equatable, Sendable {
    /// Mirrors the FFI kind discriminants (markive_ffi.h). Order matters.
    enum Kind: UInt8, CaseIterable, Sendable {
        case heading, emphasis, strong, codeSpan, codeBlock, link, listMarker, blockquote
        case codeKeyword, codeString, codeComment, codeNumber, codeFunction, codeType
    }

    var range: NSRange
    var kind: Kind
}

/// Swift face of the markive-core Rust pipeline (crates/markive-ffi).
enum MarkiveCore {
    nonisolated static func analyzeDocument(markdown: String) -> DocumentAnalysis? {
        let json: UnsafeMutablePointer<CChar>? = markdown.withCString {
            mk_analyze_document($0)
        }
        guard let json else { return nil }
        defer { mk_string_free(json) }
        let data = Data(bytes: json, count: strlen(json))
        return try? JSONDecoder().decode(DocumentAnalysis.self, from: data)
    }

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

    /// Extracts editor highlight spans from the same grammar the preview
    /// renders. Pure and thread-safe; call off the main thread.
    ///
    /// The FFI reports UTF-8 byte offsets; TextKit wants UTF-16. The
    /// conversion is one linear pass mapping only the offsets the spans
    /// actually use. A span whose offset doesn't land on a scalar
    /// boundary (impossible from a correct parser) is dropped, not
    /// misapplied.
    nonisolated static func highlightSpans(markdown: String) -> [EditorHighlight] {
        var count = 0
        let spans: UnsafeMutablePointer<MkSpan>? = markdown.withCString {
            mk_highlight_spans($0, &count)
        }
        guard let spans else { return [] }
        defer { mk_spans_free(spans, count) }
        let raw = UnsafeBufferPointer(start: spans, count: count)

        var boundaries = Set<Int>()
        for span in raw {
            boundaries.insert(Int(span.start))
            boundaries.insert(Int(span.end))
        }
        let utf16Offsets = utf8ToUTF16Offsets(markdown, at: boundaries)

        return raw.compactMap { span in
            guard let kind = EditorHighlight.Kind(rawValue: span.kind),
                  let start = utf16Offsets[Int(span.start)],
                  let end = utf16Offsets[Int(span.end)],
                  start < end else { return nil }
            return EditorHighlight(
                range: NSRange(location: start, length: end - start),
                kind: kind
            )
        }
    }

    /// Maps the requested UTF-8 byte offsets of `string` to UTF-16 code
    /// unit offsets. Only offsets on scalar boundaries appear in the
    /// result.
    nonisolated static func utf8ToUTF16Offsets(
        _ string: String, at utf8Offsets: Set<Int>
    ) -> [Int: Int] {
        var mapped = [Int: Int](minimumCapacity: utf8Offsets.count)
        var utf8Offset = 0
        var utf16Offset = 0
        for scalar in string.unicodeScalars {
            if utf8Offsets.contains(utf8Offset) {
                mapped[utf8Offset] = utf16Offset
            }
            utf8Offset += UTF8.width(scalar)
            utf16Offset += UTF16.width(scalar)
        }
        if utf8Offsets.contains(utf8Offset) {
            mapped[utf8Offset] = utf16Offset
        }
        return mapped
    }
}
