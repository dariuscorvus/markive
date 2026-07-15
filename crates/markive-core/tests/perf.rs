//! Performance budget for large documents (#17).
//!
//! Generates deterministic 1 MB, 5 MB, and 20 MB Markdown fixtures and
//! records open and render timings in the test output — run with
//! `cargo test -p markive-core --test perf -- --nocapture` to see them.
//! The asserted budgets are deliberately generous: they catch order-of-
//! magnitude regressions, not machine-to-machine noise.

use std::fmt::Write as _;
use std::path::Path;
use std::time::{Duration, Instant};

const MB: usize = 1024 * 1024;

/// Debug builds run roughly an order of magnitude slower; the budget
/// scales so `cargo test` stays meaningful in both profiles.
fn budget(release_ms: u64) -> Duration {
    let factor = if cfg!(debug_assertions) { 10 } else { 1 };
    Duration::from_millis(release_ms * factor)
}

/// A representative Markdown mix: headings, inline styles, links,
/// lists, fenced code, and images. Deterministic, so timings compare
/// across runs.
fn synthetic_markdown(target_bytes: usize) -> String {
    let mut markdown = String::with_capacity(target_bytes + 1024);
    markdown.push_str("# Perf fixture\n\n");

    let mut section = 0usize;
    while markdown.len() < target_bytes {
        section += 1;
        write!(
            markdown,
            "## Section {section}\n\n\
             Paragraph {section} with **bold**, *italic*, `code`, and a \
             [link](docs/other-{}.md). Lorem ipsum dolor sit amet, consectetur \
             adipiscing elit, sed do eiusmod tempor incididunt ut labore.\n\n\
             - item one of section {section}\n\
             - item two with `inline code`\n\
             - item three\n\n\
             ```rust\n\
             fn section_{section}() -> usize {{\n    {section} * 42\n}}\n\
             ```\n\n\
             ![figure {section}](images/fig-{}.png)\n\n",
            section % 50,
            section % 20,
        )
        .expect("write to string");
    }

    markdown
}

#[test]
fn render_large_documents_within_budget() {
    for (label, size, release_ms) in [("1 MB", MB, 500), ("5 MB", 5 * MB, 2_500), ("20 MB", 20 * MB, 10_000)] {
        let markdown = synthetic_markdown(size);

        let start = Instant::now();
        let rendered = markive_core::render_document(&markdown, Some(Path::new("/docs")));
        let elapsed = start.elapsed();

        println!(
            "render {label}: {}ms in, {} bytes html out, {} local images",
            elapsed.as_millis(),
            rendered.html().len(),
            rendered.local_images().len(),
        );

        assert!(rendered.html().contains("Perf fixture"));
        assert!(
            elapsed < budget(release_ms),
            "rendering {label} took {}ms, budget {}ms",
            elapsed.as_millis(),
            budget(release_ms).as_millis(),
        );
    }
}

#[test]
fn open_a_large_file_within_budget() {
    let markdown = synthetic_markdown(5 * MB);
    let path = std::env::temp_dir().join(format!("markive-perf-{}.md", std::process::id()));
    std::fs::write(&path, &markdown).expect("write fixture");

    let start = Instant::now();
    let document = markive_core::open_document(&path).expect("open fixture");
    let elapsed = start.elapsed();

    println!("open 5 MB: {}ms", elapsed.as_millis());
    assert_eq!(document.content().len(), markdown.len());
    assert!(
        elapsed < budget(500),
        "opening 5 MB took {}ms",
        elapsed.as_millis()
    );

    std::fs::remove_file(&path).expect("remove fixture");
}
