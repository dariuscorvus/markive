import AppKit
import Testing
@testable import Markive

@Suite struct MarkdownListEditingTests {
    @Test func recognizesMarkers() {
        #expect(MarkdownListEditing.marker(ofLine: "- item")?.marker == "-")
        #expect(MarkdownListEditing.marker(ofLine: "* item")?.marker == "*")
        #expect(MarkdownListEditing.marker(ofLine: "+ item")?.marker == "+")
        #expect(MarkdownListEditing.marker(ofLine: "12. item")?.marker == "12.")
        #expect(MarkdownListEditing.marker(ofLine: "3) item")?.marker == "3)")
        #expect(MarkdownListEditing.marker(ofLine: "  - nested")?.indent == "  ")
        #expect(MarkdownListEditing.marker(ofLine: "- [x] done")?.checkbox == "[x]")
        #expect(MarkdownListEditing.marker(ofLine: "plain text") == nil)
        #expect(MarkdownListEditing.marker(ofLine: "-not a list") == nil)
        #expect(MarkdownListEditing.marker(ofLine: "1x. not ordered") == nil)
    }

    @Test func emptinessAndContentStart() {
        let empty = MarkdownListEditing.marker(ofLine: "- ")
        #expect(empty?.isEmpty == true)
        let full = MarkdownListEditing.marker(ofLine: "- item")
        #expect(full?.isEmpty == false)
        #expect(full?.contentStart == 2)
        #expect(MarkdownListEditing.marker(ofLine: "  1. x")?.contentStart == 5)
    }

    @Test func returnContinuesBulletsAndNumbers() {
        #expect(
            MarkdownListEditing.returnAction(forLine: "- item", caretOffset: 6)
                == .continueList(prefix: "- ")
        )
        #expect(
            MarkdownListEditing.returnAction(forLine: "  3. item", caretOffset: 9)
                == .continueList(prefix: "  4. ")
        )
        #expect(
            MarkdownListEditing.returnAction(forLine: "- [x] done", caretOffset: 10)
                == .continueList(prefix: "- [ ] ")
        )
    }

    @Test func returnOnEmptyItemEndsTheList() {
        #expect(
            MarkdownListEditing.returnAction(forLine: "- ", caretOffset: 2)
                == .endList(markerLength: 2)
        )
        #expect(
            MarkdownListEditing.returnAction(forLine: "  2. ", caretOffset: 5)
                == .endList(markerLength: 5)
        )
    }

    @Test func returnBeforeContentIsPlain() {
        #expect(MarkdownListEditing.returnAction(forLine: "- item", caretOffset: 0) == nil)
        #expect(MarkdownListEditing.returnAction(forLine: "plain", caretOffset: 3) == nil)
    }

    @Test func outdentLengths() {
        #expect(MarkdownListEditing.outdentLength(ofLine: "    - item") == 4)
        #expect(MarkdownListEditing.outdentLength(ofLine: "  - item") == 2)
        #expect(MarkdownListEditing.outdentLength(ofLine: "\t- item") == 1)
        #expect(MarkdownListEditing.outdentLength(ofLine: "- item") == 0)
    }

    // MARK: - Through the editor delegate

    @MainActor
    private func makeEditor(text: String, caret: Int) -> (NSTextView, MarkdownTextView.Coordinator) {
        let document = MarkdownDocument()
        document.replaceText(text)
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textContentStorage?.textStorage = document.textStorage
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        let coordinator = MarkdownTextView.Coordinator(document: document)
        textView.delegate = coordinator
        return (textView, coordinator)
    }

    @MainActor @Test func returnKeyContinuesListInTextView() {
        let (textView, coordinator) = makeEditor(text: "- one", caret: 5)
        let handled = coordinator.textView(
            textView, doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled)
        #expect(textView.string == "- one\n- ")
        #expect(textView.selectedRange().location == 8)
    }

    @MainActor @Test func returnKeyOnEmptyItemRemovesMarker() {
        let (textView, coordinator) = makeEditor(text: "- one\n- ", caret: 8)
        let handled = coordinator.textView(
            textView, doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled)
        #expect(textView.string == "- one\n")
    }

    @MainActor @Test func tabIndentsAndBacktabOutdentsListLine() {
        let (textView, coordinator) = makeEditor(text: "- one", caret: 5)
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(textView.string == "    - one")
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(textView.string == "- one")
    }

    @MainActor @Test func tabOnPlainTextIsNotHandled() {
        let (textView, coordinator) = makeEditor(text: "plain", caret: 5)
        #expect(!coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(textView.string == "plain")
    }
}
