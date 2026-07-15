//! Memory bound for repeated large renders (#17). Lives in its own
//! test binary so parallel perf tests in the same process cannot
//! contaminate the resident-set measurement.

use std::path::Path;

const MB: usize = 1024 * 1024;

/// A representative Markdown mix, identical to the perf fixture.
fn synthetic_markdown(target_bytes: usize) -> String {
    use std::fmt::Write as _;

    let mut markdown = String::with_capacity(target_bytes + 1024);
    markdown.push_str("# Perf fixture\n\n");

    let mut section = 0usize;
    while markdown.len() < target_bytes {
        section += 1;
        write!(
            markdown,
            "## Section {section}\n\nParagraph {section} with **bold** and a [link](docs/other-{}.md).\n\n```rust\nfn section_{section}() {{}}\n```\n\n![figure {section}](images/fig-{}.png)\n\n",
            section % 50,
            section % 20,
        )
        .expect("write to string");
    }

    markdown
}

/// Resident set size of this test process, in bytes.
fn resident_bytes() -> usize {
    let output = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .expect("run ps");
    String::from_utf8(output.stdout)
        .expect("ps output is UTF-8")
        .trim()
        .parse::<usize>()
        .expect("parse rss")
        * 1024
}

#[test]
#[ignore = "takes ~90s; run with: cargo test -p markive-core --test perf_memory -- --ignored --nocapture"]
fn repeated_renders_keep_memory_bounded() {
    let markdown = synthetic_markdown(5 * MB);

    // Warm up once so allocator pools and caches are established
    // before sampling starts.
    let _ = markive_core::render_document(&markdown, Some(Path::new("/docs")));

    // RSS oscillates with allocator churn during these renders, so the
    // bound is on the low-water mark: transient spikes come and go, but
    // a real per-render leak would push the floor up run over run.
    let mut samples = Vec::new();
    for _ in 0..30 {
        let rendered = markive_core::render_document(&markdown, Some(Path::new("/docs")));
        assert!(!rendered.html().is_empty());
        samples.push(resident_bytes());
    }

    // The first ~10 renders ramp the allocator to its steady state;
    // the comparison starts after that.
    let floor_early = *samples[10..20].iter().min().expect("early samples");
    let floor_late = *samples[20..].iter().min().expect("late samples");
    let growth = floor_late.saturating_sub(floor_early);
    println!(
        "memory floor: early {} MB, late {} MB, growth {} MB",
        floor_early / MB,
        floor_late / MB,
        growth / MB,
    );

    // Ten further renders of a 5 MB document leaking even a tenth of
    // their transient allocations would blow this bound.
    assert!(
        growth < 100 * MB,
        "memory floor grew {} MB across repeated renders",
        growth / MB
    );
}
