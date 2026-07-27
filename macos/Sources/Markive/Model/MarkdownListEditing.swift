import Foundation

/// Pure line-level logic behind the editor's list-editing behavior:
/// Return continues a list item, Return on an empty item ends the list,
/// Tab/Shift-Tab indent and outdent items. The NSTextView delegate glue
/// lives in MarkdownTextView; everything decidable from the line text is
/// decided here, where it's unit-testable.
enum MarkdownListEditing {
    /// One indent step. Four spaces nests correctly under both bullet
    /// ("- ", content column 2) and ordered ("1. ", column 3) parents.
    static let indentUnit = "    "

    /// A recognized list marker at the start of a line.
    struct Marker: Equatable {
        /// Leading whitespace before the marker.
        var indent: String
        /// The marker itself: "-", "*", "+", or digits plus "." / ")".
        var marker: String
        /// A task checkbox ("[ ]" / "[x]") following the marker, if any.
        var checkbox: String?
        /// Offset (UTF-16) from line start to where content begins.
        var contentStart: Int
        /// The line has nothing but the marker (and optional checkbox).
        var isEmpty: Bool
    }

    /// Parses a list marker from a single line (no trailing newline
    /// required). Returns nil when the line is not a list item.
    static func marker(ofLine line: String) -> Marker? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" {
            index += 1
        }
        let indent = String(String.UnicodeScalarView(scalars[..<index]))

        let markerStart = index
        if index < scalars.count, "-*+".unicodeScalars.contains(scalars[index]) {
            index += 1
        } else {
            var digits = 0
            while index < scalars.count, ("0"..."9").contains(Character(scalars[index])) {
                index += 1
                digits += 1
            }
            guard digits > 0, index < scalars.count,
                  scalars[index] == "." || scalars[index] == ")" else { return nil }
            index += 1
        }
        let marker = String(String.UnicodeScalarView(scalars[markerStart..<index]))

        // The marker must be followed by a space (or end the line).
        guard index == scalars.count || scalars[index] == " " else { return nil }
        if index < scalars.count { index += 1 }

        var checkbox: String?
        if index + 2 < scalars.count,
           scalars[index] == "[", scalars[index + 2] == "]",
           scalars[index + 1] == " " || scalars[index + 1] == "x" || scalars[index + 1] == "X",
           index + 3 == scalars.count || scalars[index + 3] == " " {
            checkbox = String(String.UnicodeScalarView(scalars[index..<index + 3]))
            index += 3
            if index < scalars.count { index += 1 }
        }

        let rest = scalars[index...]
        let isEmpty = rest.allSatisfy { $0 == " " || $0 == "\t" }
        // Every scalar consumed so far is one UTF-16 unit (ASCII).
        return Marker(
            indent: indent, marker: marker, checkbox: checkbox,
            contentStart: index, isEmpty: isEmpty
        )
    }

    /// What Return should do on a list line.
    enum ReturnAction: Equatable {
        /// Insert a newline plus this continuation prefix.
        case continueList(prefix: String)
        /// Empty item: delete the marker (line start through contentStart)
        /// instead of inserting anything — Return ends the list.
        case endList(markerLength: Int)
    }

    /// Decides the Return behavior for a line, given the caret's offset
    /// within that line. Returns nil for non-list lines and for carets
    /// before the content (where a plain newline is right).
    static func returnAction(forLine line: String, caretOffset: Int) -> ReturnAction? {
        guard let marker = marker(ofLine: line), caretOffset >= marker.contentStart else {
            return nil
        }
        if marker.isEmpty {
            return .endList(markerLength: marker.contentStart)
        }
        let next: String
        if let ordinal = Int(marker.marker.dropLast()) {
            next = "\(ordinal + 1)\(marker.marker.suffix(1))"
        } else {
            next = marker.marker
        }
        let checkbox = marker.checkbox == nil ? "" : "[ ] "
        return .continueList(prefix: "\(marker.indent)\(next) \(checkbox)")
    }

    /// The number of characters (UTF-16 units) to delete from the start
    /// of the line to outdent one step: a full indent unit if present,
    /// otherwise whatever leading spaces or single tab there is. Zero
    /// means nothing to outdent.
    static func outdentLength(ofLine line: String) -> Int {
        if line.hasPrefix(indentUnit) { return indentUnit.count }
        if line.hasPrefix("\t") { return 1 }
        var count = 0
        for character in line {
            guard character == " ", count < indentUnit.count else { break }
            count += 1
        }
        return count
    }
}
