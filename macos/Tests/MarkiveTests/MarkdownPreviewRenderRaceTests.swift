import Foundation
import Testing

/// `MarkdownPreviewView`'s `.task(id:)` can't be driven directly here — it
/// needs a live SwiftUI view host, which this project has no harness for.
/// This instead isolates the exact hazard that caused stale preview
/// content after switching documents: Task cancellation is cooperative,
/// so a render already in flight when the user switches documents again
/// keeps running to completion regardless, and — without an explicit
/// `Task.isCancelled` guard before the final write — a slow, superseded
/// render finishing *after* a newer one would silently overwrite the
/// correct, already-displayed content. Mirrors the shape of the real fix
/// in MarkdownPreviewView.swift closely enough to stand in for it.
@Suite struct MarkdownPreviewRenderRaceTests {
    actor Result {
        var value: String?
        func set(_ newValue: String) { value = newValue }
    }

    /// `Thread.sleep` is `noasync` — hidden behind this plain sync
    /// function so it can be called from the detached task's async body.
    private func blockingSleep(milliseconds: UInt64) {
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
    }

    /// Mirrors the real render() exactly: synchronous, CPU-bound work
    /// inside `Task.detached`. Deliberately not `Task.sleep` — sleep
    /// throws on cancellation and returns early, which would mask the
    /// hazard this test exists to catch. A detached task's blocking work,
    /// like the real markdown render, does not observe cancellation.
    private func render(_ label: String, delayMilliseconds: UInt64) async -> String {
        await Task.detached(priority: .userInitiated) { [self] in
            blockingSleep(milliseconds: delayMilliseconds)
            return label
        }.value
    }

    @Test func aSlowSupersededRenderNeverOverwritesTheNewerOne() async {
        let result = Result()

        // Document A's render starts first but is slow (a big document).
        let taskA = Task {
            let html = await render("A", delayMilliseconds: 100)
            guard !Task.isCancelled else { return }
            await result.set(html)
        }
        // The user switches to B before A finishes; B renders fast.
        try? await Task.sleep(nanoseconds: 10_000_000)
        taskA.cancel()
        let taskB = Task {
            let html = await render("B", delayMilliseconds: 10)
            guard !Task.isCancelled else { return }
            await result.set(html)
        }

        _ = await taskA.value
        _ = await taskB.value

        // B finished first and set "B" — A must not clobber it after,
        // even though A's own render work ran to completion anyway.
        #expect(await result.value == "B")
    }

    @Test func withoutTheCancellationGuardTheSlowerFinisherWins() async {
        // Same race, but without checking Task.isCancelled — demonstrates
        // the actual bug this project shipped: whichever render happens to
        // finish last wins, regardless of which document is selected.
        let result = Result()

        let taskA = Task {
            let html = await render("A", delayMilliseconds: 100)
            await result.set(html)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        taskA.cancel()
        let taskB = Task {
            let html = await render("B", delayMilliseconds: 10)
            await result.set(html)
        }

        _ = await taskA.value
        _ = await taskB.value

        #expect(await result.value == "A")
    }
}
