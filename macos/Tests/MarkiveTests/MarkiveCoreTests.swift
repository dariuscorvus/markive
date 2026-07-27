import Foundation
import Testing
@testable import Markive

@Suite struct MarkiveCoreTests {
    @Test func rendersSanitizedHTML() {
        let html = MarkiveCore.renderDocument(
            markdown: "# Hello\n\n*world* <script>alert(1)</script>",
            baseDir: nil
        )
        #expect(html.contains("<h1"))
        #expect(html.contains("<em>world</em>"))
        #expect(!html.contains("<script"))
    }

    @Test func emptyInputRendersEmpty() {
        #expect(MarkiveCore.renderDocument(markdown: "", baseDir: nil).isEmpty)
    }

    /// The FFI boundary must not blow up the markive-core perf budget
    /// (crates/markive-core/tests/perf.rs). The Rust side is release-built;
    /// the generous ceiling catches order-of-magnitude regressions only.
    @Test func twentyMegabyteFixtureRendersWithinBudget() {
        var markdown = "# Perf fixture\n\n"
        markdown.reserveCapacity(21 * 1024 * 1024)
        var section = 0
        while markdown.utf8.count < 20 * 1024 * 1024 {
            markdown += """
            ## Section \(section)

            Some *inline* **styles**, a [link](https://example.com/\(section)), and `code`.

            - item one
            - item two

            ```swift
            let value = \(section)
            ```


            """
            section += 1
        }

        let start = ContinuousClock.now
        let html = MarkiveCore.renderDocument(markdown: markdown, baseDir: nil)
        let elapsed = ContinuousClock.now - start

        #expect(html.contains("<h2"))
        #expect(html.utf8.count > 20 * 1024 * 1024 / 2)
        #expect(elapsed < .seconds(10), "20 MB render took \(elapsed)")
        print("20 MB render through FFI: \(elapsed)")
    }

    // MARK: - Highlight spans

    @Test func highlightSpansCoverConstructs() {
        let markdown = "# Title\n\nSome *em* and **strong** and `code`.\n"
        let spans = MarkiveCore.highlightSpans(markdown: markdown)
        let text = markdown as NSString
        let slice = { (kind: EditorHighlight.Kind) in
            spans.filter { $0.kind == kind }.map { text.substring(with: $0.range) }
        }
        #expect(slice(.heading) == ["# Title\n"])
        #expect(slice(.emphasis) == ["*em*"])
        #expect(slice(.strong) == ["**strong**"])
        #expect(slice(.codeSpan) == ["`code`"])
    }

    @Test func highlightSpansUseUTF16Ranges() {
        // Multi-byte scalars before and inside the construct: "é" is
        // 2 UTF-8 bytes / 1 UTF-16 unit, "🎉" is 4 bytes / 2 units.
        // Raw byte offsets applied as NSRanges would land mid-word.
        let markdown = "héllo 🎉 **wörld** and `codé`\n"
        let spans = MarkiveCore.highlightSpans(markdown: markdown)
        let text = markdown as NSString
        let strong = spans.first { $0.kind == .strong }
        let code = spans.first { $0.kind == .codeSpan }
        #expect(strong.map { text.substring(with: $0.range) } == "**wörld**")
        #expect(code.map { text.substring(with: $0.range) } == "`codé`")
    }

    @Test func highlightSpansOnEmptyInput() {
        #expect(MarkiveCore.highlightSpans(markdown: "").isEmpty)
        #expect(MarkiveCore.highlightSpans(markdown: "plain words\n").isEmpty)
    }

    @Test func utf8ToUTF16OffsetMapping() {
        // "a🎉b": UTF-8 offsets 0,1,5,6 ↔ UTF-16 offsets 0,1,3,4.
        let mapped = MarkiveCore.utf8ToUTF16Offsets("a🎉b", at: [0, 1, 5, 6, 3])
        #expect(mapped == [0: 0, 1: 1, 5: 3, 6: 4])
        // Offset 3 is mid-emoji — not a scalar boundary, so unmapped.
        #expect(mapped[3] == nil)
    }
}
