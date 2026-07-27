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
}
