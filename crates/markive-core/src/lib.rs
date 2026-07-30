#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use std::path::Component;

use ammonia::Builder;
use percent_encoding::percent_decode_str;
use pulldown_cmark::{CodeBlockKind, CowStr, Event, Options, Parser, Tag, TagEnd};

mod analysis;
mod code_highlight;
pub use analysis::{DocumentAnalysis, analyze_document, analyze_document_json};
use code_highlight::CodeToken;

/// File extensions Markive treats as Markdown documents.
pub const MARKDOWN_EXTENSIONS: [&str; 4] = ["md", "markdown", "mdown", "mkd"];

/// Returns true when the path has a Markdown file extension.
#[must_use]
pub fn is_markdown_path(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| {
            MARKDOWN_EXTENSIONS
                .iter()
                .any(|known| extension.eq_ignore_ascii_case(known))
        })
}

#[derive(Debug, Eq, PartialEq)]
pub struct Document {
    path: PathBuf,
    content: String,
}

impl Document {
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub fn content(&self) -> &str {
        &self.content
    }
}

/// Reads a UTF-8 document without modifying it.
///
/// # Errors
///
/// Returns an error when the file cannot be read or is not valid UTF-8.
pub fn open_document(path: impl AsRef<Path>) -> io::Result<Document> {
    let path = path.as_ref();
    let content = fs::read_to_string(path)?;

    Ok(Document {
        path: path.to_path_buf(),
        content,
    })
}

/// Saves `content` to `path` without risking the original: the content
/// goes to a temporary file in the same directory, is flushed to disk,
/// and atomically renamed over the original. A failure at any step
/// leaves the original file unchanged.
///
/// # Errors
///
/// Returns an error when the target is read-only, the directory is not
/// writable, or any write, flush, or rename fails.
pub fn save_document(path: &Path, content: &str) -> io::Result<()> {
    let original = fs::metadata(path);

    // rename() replaces a read-only file when the directory is
    // writable; refusing here keeps the read-only bit meaningful.
    if let Ok(metadata) = &original
        && metadata.permissions().readonly()
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is read-only", path.display()),
        ));
    }

    let directory = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no directory"))?;
    let file_name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    let temp = directory.join(format!(
        ".{}.markive-{}.tmp",
        file_name.to_string_lossy(),
        std::process::id()
    ));

    let result = (|| {
        let mut file = fs::File::create(&temp)?;
        io::Write::write_all(&mut file, content.as_bytes())?;
        file.sync_all()?;
        // The rename keeps the temp file's permissions, not the
        // original's; carry them over.
        if let Ok(metadata) = &original {
            fs::set_permissions(&temp, metadata.permissions())?;
        }
        fs::rename(&temp, path)
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }

    result
}

/// A document rendered against a filesystem base directory.
#[derive(Debug, Eq, PartialEq)]
pub struct RenderedDocument {
    html: String,
    local_images: Vec<PathBuf>,
}

impl RenderedDocument {
    #[must_use]
    pub fn html(&self) -> &str {
        &self.html
    }

    /// Absolute paths of every local image the document references.
    #[must_use]
    pub fn local_images(&self) -> &[PathBuf] {
        &self.local_images
    }
}

fn markdown_options() -> Options {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_FOOTNOTES);
    options
}

fn sanitize(html: &str) -> String {
    let mut builder = Builder::default();
    // Allow common structural HTML elements and attributes for markdown documents.
    builder
        .add_tags([
            "div", "section", "article", "aside", "main", "figure", "figcaption",
            "details", "summary", "dialog", "data", "mark", "meter", "progress", "time",
            "input", "button",
        ])
        .add_tag_attributes("div", ["class", "id", "tabindex"])
        .add_tag_attributes("section", ["class", "id"])
        .add_tag_attributes("article", ["class", "id"])
        .add_tag_attributes("figure", ["class", "id"])
        // `language-xxx` on `<code>` and `tok-xxx` on `<span>`, both from
        // the fenced-code-block highlighter's own fixed vocabulary.
        .add_tag_attributes("code", ["class"])
        .add_tag_attributes("span", ["class", "id"])
        .add_tag_attributes("sup", ["class", "id", "tabindex"])
        .add_tag_attributes("a", ["class", "id"])
        .add_tag_attributes("details", ["open"])
        .add_tag_attributes("input", ["checked", "disabled", "type"])
        .add_tag_attributes("button", ["disabled", "type"])
        .add_tag_attributes("data", ["value"])
        .add_tag_attributes("meter", ["value", "min", "max", "low", "high"])
        .add_tag_attributes("progress", ["value", "max"])
        .add_tag_attributes("time", ["datetime"]);
    builder.add_url_schemes(&["markive-create"]);
    // GitHub keeps the legacy `align` attribute; READMEs rely on it to
    // center images and badges.
    for tag in ["p", "div", "td", "th"] {
        builder.add_tag_attributes(tag, ["align"]);
    }
    for heading in ["h1", "h2", "h3", "h4", "h5", "h6"] {
        builder.add_tag_attributes(heading, ["id"]);
    }
    builder.clean(html).to_string()
}

/// GitHub-style anchor slug: lowercase, alphanumerics kept, spaces and
/// hyphens become hyphens, everything else dropped.
fn slugify(text: &str) -> String {
    text.chars()
        .filter_map(|c| {
            if c.is_alphanumeric() {
                Some(c.to_lowercase().next().unwrap_or(c))
            } else if c == ' ' || c == '-' {
                Some('-')
            } else {
                None
            }
        })
        .collect()
}

/// Parses Markdown and gives every heading without an explicit id a
/// slug generated from its text, deduplicated with `-N` suffixes.
fn events_with_heading_ids(markdown: &str) -> Vec<Event<'_>> {
    let mut events: Vec<Event> = Parser::new_ext(markdown, markdown_options()).collect();
    let mut seen = std::collections::HashMap::<String, usize>::new();

    for index in 0..events.len() {
        let Event::Start(Tag::Heading { id: None, .. }) = &events[index] else {
            continue;
        };

        let mut text = String::new();
        for event in &events[index + 1..] {
            match event {
                Event::End(TagEnd::Heading(_)) => break,
                Event::Text(t) | Event::Code(t) => text.push_str(t),
                _ => {}
            }
        }

        let slug = slugify(&text);
        let count = seen.entry(slug.clone()).or_insert(0);
        let unique = if *count == 0 {
            slug
        } else {
            format!("{slug}-{count}")
        };
        *count += 1;

        if let Event::Start(Tag::Heading { id, .. }) = &mut events[index] {
            *id = Some(unique.into());
        }
    }

    events
}

/// Gives every footnote reference its own anchor, adds a backlink from each
/// definition to every reference, and leaves missing definitions visibly
/// unresolved. The generated links are native anchors, so `WebKit` exposes them
/// to Tab/Shift-Tab and Return without JavaScript.
fn events_with_footnote_navigation(events: Vec<Event<'_>>) -> Vec<Event<'_>> {
    use std::collections::{HashMap, HashSet};

    let definitions: HashSet<String> = events
        .iter()
        .filter_map(|event| match event {
            Event::Start(Tag::FootnoteDefinition(name)) => Some(name.to_string()),
            _ => None,
        })
        .collect();
    let mut reference_totals = HashMap::<String, usize>::new();
    for event in &events {
        if let Event::FootnoteReference(name) = event {
            *reference_totals.entry(name.to_string()).or_default() += 1;
        }
    }

    let mut numbers = HashMap::<String, usize>::new();
    let mut reference_counts = HashMap::<String, usize>::new();
    let mut definition_stack = Vec::<String>::new();
    let mut output = Vec::with_capacity(events.len());

    for event in events {
        match event {
            Event::FootnoteReference(name) => {
                let label = name.to_string();
                if !definitions.contains(&label) {
                    let mut escaped = String::new();
                    escape_html_text(&mut escaped, &label);
                    output.push(Event::Html(
                        format!(
                            "<sup class=\"footnote-reference unresolved-footnote\">[^{escaped}]</sup>"
                        )
                        .into(),
                    ));
                    continue;
                }
                let next_number = numbers.len() + 1;
                let number = *numbers.entry(label.clone()).or_insert(next_number);
                let ordinal = reference_counts.entry(label.clone()).or_default();
                *ordinal += 1;
                let id = footnote_id(&label);
                output.push(Event::Html(
                    format!(
                        "<sup class=\"footnote-reference\" id=\"fnref-{id}-{ordinal}\" tabindex=\"-1\"><a href=\"#fn-{id}\">{number}</a></sup>"
                    )
                    .into(),
                ));
            }
            Event::Start(Tag::FootnoteDefinition(name)) => {
                let label = name.to_string();
                let next_number = numbers.len() + 1;
                let number = *numbers.entry(label.clone()).or_insert(next_number);
                let id = footnote_id(&label);
                definition_stack.push(label);
                output.push(Event::Html(
                    format!(
                        "<div class=\"footnote-definition\" id=\"fn-{id}\" tabindex=\"-1\"><sup class=\"footnote-definition-label\">{number}</sup>"
                    )
                    .into(),
                ));
            }
            Event::End(TagEnd::FootnoteDefinition) => {
                if let Some(label) = definition_stack.pop() {
                    let id = footnote_id(&label);
                    let total = reference_totals.get(&label).copied().unwrap_or_default();
                    let mut backlinks = String::from("<span class=\"footnote-backlinks\">");
                    for ordinal in 1..=total {
                        let suffix = if ordinal == 1 {
                            String::new()
                        } else {
                            ordinal.to_string()
                        };
                        let _ = write!(
                            backlinks,
                            " <a href=\"#fnref-{id}-{ordinal}\" class=\"footnote-backlink\">↩{suffix}</a>"
                        );
                    }
                    backlinks.push_str("</span></div>");
                    output.push(Event::Html(backlinks.into()));
                }
            }
            other => output.push(other),
        }
    }
    output
}

fn footnote_id(label: &str) -> String {
    let slug = slugify(label);
    let mut bytes = String::new();
    for byte in label.as_bytes() {
        let _ = write!(bytes, "{byte:02x}");
    }
    format!("{}-{bytes}", if slug.is_empty() { "note" } else { &slug })
}

/// Replaces each fenced code block that names a recognized language with
/// a pre-rendered, syntax-highlighted `<pre><code>` [`Event::Html`]. Fences
/// with no info string, an unrecognized language, or indented code blocks
/// pass through untouched — `pulldown_cmark::html` renders those as it
/// always has.
fn highlight_code_blocks(events: Vec<Event<'_>>) -> Vec<Event<'_>> {
    let mut output = Vec::with_capacity(events.len());
    let mut iter = events.into_iter();

    while let Some(event) = iter.next() {
        let language = match &event {
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info))) => {
                info.split_whitespace().next().map(str::to_owned)
            }
            _ => None,
        };
        let Some(language) = language.filter(|lang| !lang.is_empty()) else {
            output.push(event);
            continue;
        };

        let mut code = String::new();
        for next in iter.by_ref() {
            match next {
                Event::Text(text) => code.push_str(&text),
                Event::End(TagEnd::CodeBlock) => break,
                _ => {}
            }
        }

        let mut html = format!(
            "<pre><code class=\"language-{}\">",
            encode_attribute(&language)
        );
        highlight_code_block_html(&mut html, &code, &language);
        html.push_str("</code></pre>");
        output.push(Event::Html(CowStr::from(html)));
    }

    output
}

/// Appends `code`, highlighted as `language`, to `out` as HTML: each
/// classified token wrapped in `<span class="tok-KIND">`, everything
/// else escaped plain text. `code` and unclassified text are identical
/// to what pulldown-cmark's own writer would have escaped.
fn highlight_code_block_html(out: &mut String, code: &str, language: &str) {
    let mut pos = 0usize;
    for span in code_highlight::highlight(code, language) {
        if span.start > pos {
            escape_html_text(out, &code[pos..span.start]);
        }
        let _ = write!(out, "<span class=\"{}\">", token_class(span.token));
        escape_html_text(out, &code[span.start..span.end]);
        out.push_str("</span>");
        pos = span.end;
    }
    if pos < code.len() {
        escape_html_text(out, &code[pos..]);
    }
}

fn token_class(token: CodeToken) -> &'static str {
    match token {
        CodeToken::Keyword => "tok-keyword",
        CodeToken::String => "tok-string",
        CodeToken::Comment => "tok-comment",
        CodeToken::Number => "tok-number",
        CodeToken::Function => "tok-function",
        CodeToken::Type => "tok-type",
    }
}

fn escape_html_text(out: &mut String, text: &str) {
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
}

#[must_use]
pub fn render_markdown(markdown: &str) -> String {
    let mut html = String::new();
    let events = highlight_code_blocks(events_with_footnote_navigation(
        events_with_heading_ids(markdown),
    ));
    pulldown_cmark::html::push_html(&mut html, events.into_iter());

    sanitize(&html)
}

/// Renders Markdown with local image sources resolved to absolute
/// paths under `base_dir` (the directory of the document).
///
/// Remote (`http:`, `https:`, protocol-relative) sources are left
/// untouched. Relative sources are joined to `base_dir` and normalized
/// lexically; absolute sources are normalized in place. Every resolved
/// path is reported in [`RenderedDocument::local_images`] so callers
/// can grant access to exactly those files.
///
/// Without a `base_dir` — a document that never came from a file, like
/// pasted clipboard text — only absolute sources resolve; relative
/// sources have nothing to resolve against and pass through untouched.
#[must_use]
pub fn render_document(markdown: &str, base_dir: Option<&Path>) -> RenderedDocument {
    let events = events_with_footnote_navigation(events_with_heading_ids(markdown))
        .into_iter()
        .map(|event| match event {
            // Local link targets become absolute so the app can open
            // them regardless of its working directory. Anchors and
            // URLs pass through.
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                let dest_url = if dest_url.starts_with('#') {
                    dest_url
                } else {
                    match resolve_local_target(&dest_url, base_dir) {
                        Some(path) => path.to_string_lossy().into_owned().into(),
                        None => dest_url,
                    }
                };
                Event::Start(Tag::Link {
                    link_type,
                    dest_url,
                    title,
                    id,
                })
            }
            other => other,
        })
        .collect();
    let events = highlight_code_blocks(events);

    let mut html = String::new();
    pulldown_cmark::html::push_html(&mut html, events.into_iter());

    let (html, local_images) = resolve_image_sources(&sanitize(&html), base_dir);

    RenderedDocument { html, local_images }
}

/// Resolves every `<img src>` in sanitized HTML to an absolute path.
///
/// Runs on ammonia's output — lowercase tags, double-quoted attribute
/// values — so it covers images written as raw HTML in the Markdown,
/// not just Markdown image syntax. Remote sources pass through; see
/// [`resolve_local_target`].
fn resolve_image_sources(html: &str, base_dir: Option<&Path>) -> (String, Vec<PathBuf>) {
    let mut output = String::with_capacity(html.len());
    let mut local_images = Vec::new();
    let mut rest = html;

    while let Some(tag_start) = rest.find("<img") {
        let tag = &rest[tag_start..];
        let Some(tag_len) = tag.find('>') else { break };

        let src = tag[..tag_len].find(" src=\"").and_then(|attr| {
            let value_start = tag_start + attr + " src=\"".len();
            let value_len = rest[value_start..tag_start + tag_len].find('"')?;
            Some((value_start, value_len))
        });

        if let Some((value_start, value_len)) = src {
            let value = decode_entities(&rest[value_start..value_start + value_len]);
            output.push_str(&rest[..value_start]);
            if let Some(path) = resolve_local_target(&value, base_dir) {
                output.push_str(&encode_attribute(&path.to_string_lossy()));
                if !local_images.contains(&path) {
                    local_images.push(path);
                }
            } else {
                output.push_str(&rest[value_start..value_start + value_len]);
            }
            rest = &rest[value_start + value_len..];
        } else {
            output.push_str(&rest[..tag_start + tag_len]);
            rest = &rest[tag_start + tag_len..];
        }
    }

    output.push_str(rest);
    (output, local_images)
}

/// Decodes the entities ammonia emits in attribute values.
fn decode_entities(value: &str) -> String {
    value
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

/// Escapes a resolved path for use in a double-quoted attribute value.
fn encode_attribute(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('"', "&quot;")
}

/// True when `src` names a remote or otherwise non-filesystem target:
/// a URL scheme (RFC 3986 `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`)
/// or a protocol-relative `//` prefix.
fn has_url_scheme(src: &str) -> bool {
    if src.starts_with("//") {
        return true;
    }

    src.split_once(':').is_some_and(|(scheme, _)| {
        let mut chars = scheme.chars();
        chars
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
            && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    })
}

/// Resolves an image source to an absolute filesystem path, or `None`
/// when the source is remote, empty, not decodable, or relative with
/// no base directory to resolve against.
fn resolve_local_target(src: &str, base_dir: Option<&Path>) -> Option<PathBuf> {
    if src.is_empty() || has_url_scheme(src) {
        return None;
    }

    // Markdown sources are URLs, so `my image.png` arrives as
    // `my%20image.png`; the filesystem needs the decoded form.
    let decoded = percent_decode_str(src).decode_utf8().ok()?;
    let path = Path::new(decoded.as_ref());
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        base_dir?.join(path)
    };

    Some(normalize_lexically(&joined))
}

/// Removes `.` and `..` components without touching the filesystem,
/// clamping traversal at the root.
fn normalize_lexically(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();

    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }

    normalized
}

/// What a highlight span marks. The discriminants are the FFI contract —
/// `crates/markive-ffi` exposes them as a `uint8_t` and the Swift editor
/// maps them back; never renumber, only append.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum SpanKind {
    Heading = 0,
    Emphasis = 1,
    Strong = 2,
    CodeSpan = 3,
    CodeBlock = 4,
    Link = 5,
    ListMarker = 6,
    Blockquote = 7,
    CodeKeyword = 8,
    CodeString = 9,
    CodeComment = 10,
    CodeNumber = 11,
    CodeFunction = 12,
    CodeType = 13,
}

fn code_token_span_kind(token: CodeToken) -> SpanKind {
    match token {
        CodeToken::Keyword => SpanKind::CodeKeyword,
        CodeToken::String => SpanKind::CodeString,
        CodeToken::Comment => SpanKind::CodeComment,
        CodeToken::Number => SpanKind::CodeNumber,
        CodeToken::Function => SpanKind::CodeFunction,
        CodeToken::Type => SpanKind::CodeType,
    }
}

/// A half-open `[start, end)` byte range of the source Markdown (UTF-8
/// offsets) to highlight as `kind`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HighlightSpan {
    pub start: u32,
    pub end: u32,
    pub kind: SpanKind,
}

/// Text inside a fenced code block with a recognized language, buffered
/// across possibly several `Event::Text`s so multi-line constructs
/// (block comments, multi-line strings) tokenize with full context — one
/// [`code_highlight::highlight`] call per block, not per fragment.
struct PendingCode {
    language: String,
    start: usize,
    text: String,
}

/// Extracts editor highlight spans from the same grammar the preview
/// renders — pulldown-cmark with [`markdown_options`] — so what looks
/// like a heading in the editor is exactly what renders as one.
///
/// Spans come out in event order: an enclosing construct (blockquote,
/// list item) precedes what it contains, so a consumer applying them
/// sequentially lets the innermost construct win on overlap.
#[must_use]
pub fn highlight_spans(markdown: &str) -> Vec<HighlightSpan> {
    let mut spans = Vec::new();
    let mut push = |kind: SpanKind, range: std::ops::Range<usize>| {
        // u32 covers 4 GB of Markdown; anything larger has no business
        // being syntax-highlighted (the editor opts out far earlier).
        if let (Ok(start), Ok(end)) = (u32::try_from(range.start), u32::try_from(range.end))
            && start < end
        {
            spans.push(HighlightSpan { start, end, kind });
        }
    };

    let mut pending_code: Option<PendingCode> = None;

    for (event, range) in Parser::new_ext(markdown, markdown_options()).into_offset_iter() {
        match event {
            Event::Start(Tag::Heading { .. }) => push(SpanKind::Heading, range),
            Event::Start(Tag::Emphasis) => push(SpanKind::Emphasis, range),
            Event::Start(Tag::Strong) => push(SpanKind::Strong, range),
            Event::Code(_) => push(SpanKind::CodeSpan, range),
            Event::Start(Tag::CodeBlock(kind)) => {
                push(SpanKind::CodeBlock, range);
                let language = match &kind {
                    CodeBlockKind::Fenced(info) => {
                        info.split_whitespace().next().unwrap_or("").to_owned()
                    }
                    CodeBlockKind::Indented => String::new(),
                };
                pending_code = Some(PendingCode {
                    language,
                    start: 0,
                    text: String::new(),
                });
            }
            Event::Text(text) if let Some(pending) = pending_code.as_mut() => {
                if pending.text.is_empty() {
                    pending.start = range.start;
                }
                pending.text.push_str(&text);
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some(pending) = pending_code.take()
                    && !pending.language.is_empty()
                {
                    for span in code_highlight::highlight(&pending.text, &pending.language) {
                        push(
                            code_token_span_kind(span.token),
                            pending.start + span.start..pending.start + span.end,
                        );
                    }
                }
            }
            Event::Start(Tag::Link { .. } | Tag::Image { .. }) => {
                push(SpanKind::Link, range);
            }
            Event::Start(Tag::BlockQuote(_)) => push(SpanKind::Blockquote, range),
            // An item's range starts at its marker; measure the marker
            // from the source since the parser has no marker event.
            Event::Start(Tag::Item) => {
                let marker_len = list_marker_len(&markdown[range.clone()]);
                if marker_len > 0 {
                    push(SpanKind::ListMarker, range.start..range.start + marker_len);
                }
            }
            Event::TaskListMarker(_) => push(SpanKind::ListMarker, range),
            _ => {}
        }
    }

    spans
}

/// Length in bytes of the list marker at the start of an item's source:
/// `-`, `+`, `*`, or digits followed by `.` or `)`. Zero when the item
/// text doesn't start with a recognizable marker.
fn list_marker_len(item: &str) -> usize {
    let bytes = item.as_bytes();
    match bytes.first() {
        Some(b'-' | b'+' | b'*') => 1,
        Some(b'0'..=b'9') => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            match bytes.get(digits) {
                Some(b'.' | b')') => digits + 1,
                _ => 0,
            }
        }
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;

    #[test]
    fn opens_utf8_document_without_changing_content() {
        let path = std::env::temp_dir().join(format!("markive-{}.md", process::id()));
        let content = "# Markive\n\nFiles first.\n";

        fs::write(&path, content).expect("write test document");

        let document = open_document(&path).expect("open test document");

        assert_eq!(document.path(), path.as_path());
        assert_eq!(document.content(), content);

        fs::remove_file(path).expect("remove test document");
    }

    #[test]
    fn recognizes_markdown_extensions_case_insensitively() {
        assert!(is_markdown_path(Path::new("/notes/todo.md")));
        assert!(is_markdown_path(Path::new("README.MD")));
        assert!(is_markdown_path(Path::new("doc.Markdown")));
        assert!(!is_markdown_path(Path::new("archive.md.zip")));
        assert!(!is_markdown_path(Path::new("plain.txt")));
        assert!(!is_markdown_path(Path::new("no-extension")));
    }

    #[test]
    fn renders_github_flavored_markdown() {
        let markdown =
            "# Markive\n\n~~old~~\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n- [x] rendered\n";

        let html = render_markdown(markdown);

        assert!(html.contains("<h1 id=\"markive\">Markive</h1>"));
        assert!(html.contains("<del>old</del>"));
        assert!(html.contains("<table>"));
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("checked"));
    }

    #[test]
    fn highlights_fenced_code_blocks_with_a_recognized_language() {
        let html = render_markdown("```rust\nfn add(a: i32) -> i32 {\n    a + 1\n}\n```\n");

        assert!(html.contains("<pre><code class=\"language-rust\">"));
        assert!(html.contains("<span class=\"tok-keyword\">fn</span>"));
        assert!(html.contains("<span class=\"tok-number\">1</span>"));
    }

    #[test]
    fn leaves_fences_with_no_or_unrecognized_language_as_plain_code() {
        let plain = render_markdown("```\nnaked fence\n```\n");
        assert!(plain.contains("<pre><code>naked fence"));
        assert!(!plain.contains("tok-"));

        let unknown = render_markdown("```not-a-real-language\nx\n```\n");
        assert!(unknown.contains("<pre><code class=\"language-not-a-real-language\">x"));
        assert!(!unknown.contains("tok-"));
    }

    #[test]
    fn mermaid_fences_pass_through_untokenized_for_the_client_side_renderer() {
        let html = render_markdown("```mermaid\ngraph TD\n  A --> B\n```\n");

        assert!(html.contains("<pre><code class=\"language-mermaid\">"));
        assert!(html.contains("graph TD"));
        assert!(!html.contains("tok-"));
    }

    #[test]
    fn escapes_html_metacharacters_inside_highlighted_code() {
        let html = render_markdown("```rust\nlet x: Vec<&str> = vec![\"a\", \"b\"];\n```\n");

        assert!(!html.contains("Vec<&str>"));
        assert!(html.contains("&lt;"));
        assert!(html.contains("&amp;"));
        assert!(html.contains("&gt;"));
    }

    #[test]
    fn highlighting_survives_sanitization_and_local_image_resolution() {
        let rendered = render_document(
            "```js\nconst x = 1; // comment\n```\n",
            Some(Path::new("/docs")),
        );

        assert!(rendered.html().contains("<span class=\"tok-keyword\">const</span>"));
        assert!(rendered.html().contains("tok-comment"));
    }

    #[test]
    fn save_round_trips_bytes_exactly() {
        let path = std::env::temp_dir().join(format!("markive-save-{}.md", process::id()));
        let content = "# Ünïcode 🎉\r\nCRLF line\r\n\nLF line\n";

        save_document(&path, content).expect("save document");

        assert_eq!(fs::read(&path).expect("read saved file"), content.as_bytes());
        fs::remove_file(&path).expect("remove test file");
    }

    #[test]
    fn save_replaces_existing_content() {
        let path = std::env::temp_dir().join(format!("markive-save-replace-{}.md", process::id()));
        fs::write(&path, "old").expect("write original");

        save_document(&path, "new").expect("save document");

        assert_eq!(fs::read_to_string(&path).expect("read"), "new");
        fs::remove_file(&path).expect("remove test file");
    }

    #[test]
    fn save_refuses_read_only_files_and_keeps_them_unchanged() {
        let path = std::env::temp_dir().join(format!("markive-save-ro-{}.md", process::id()));
        fs::write(&path, "protected").expect("write original");
        let mut permissions = fs::metadata(&path).expect("metadata").permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&path, permissions.clone()).expect("set read-only");

        let error = save_document(&path, "overwrite").expect_err("refuse read-only file");

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read_to_string(&path).expect("read"), "protected");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
                .expect("restore permissions");
        }
        fs::remove_file(&path).expect("remove test file");
    }

    #[test]
    fn save_into_a_missing_directory_fails_cleanly() {
        let path = Path::new("/nonexistent-markive-dir/note.md");

        assert!(save_document(path, "content").is_err());
    }

    #[test]
    fn headings_get_deduplicated_anchor_ids() {
        let html = render_markdown("# My Heading!\n\n## My Heading!\n\n### Config `opts`\n");

        assert!(html.contains("<h1 id=\"my-heading\">"));
        assert!(html.contains("<h2 id=\"my-heading-1\">"));
        assert!(html.contains("<h3 id=\"config-opts\">"));
    }

    #[test]
    fn footnotes_have_distinct_references_and_backlinks() {
        let html = render_markdown(
            "First[^note] and repeated[^note].\n\n[^note]: A defined footnote.\n",
        );

        assert!(html.contains("id=\"fnref-note-6e6f7465-1\""));
        assert!(html.contains("id=\"fnref-note-6e6f7465-2\""));
        assert!(html.contains("href=\"#fn-note-6e6f7465\""));
        assert!(html.contains("id=\"fn-note-6e6f7465\""));
        assert!(html.contains("href=\"#fnref-note-6e6f7465-1\""));
        assert!(html.contains("href=\"#fnref-note-6e6f7465-2\""));
        assert!(html.contains(">↩</a>"));
        assert!(html.contains(">↩2</a>"));
    }

    #[test]
    fn missing_footnotes_remain_visible_and_unlinked() {
        let html = render_markdown("Missing[^nowhere].");

        assert!(html.contains("[^nowhere]"));
        assert!(!html.contains("href=\"#fn-nowhere"));
    }

    #[test]
    fn resolves_relative_markdown_links_against_the_base_directory() {
        let rendered = render_document("[next](notes/next.md)", Some(Path::new("/docs")));

        assert!(rendered.html().contains("href=\"/docs/notes/next.md\""));
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn keeps_anchor_and_remote_links_untouched() {
        let markdown = "[a](#section)\n\n[b](https://example.com)\n\n[c](mailto:x@y.z)";

        let rendered = render_document(markdown, Some(Path::new("/docs")));

        assert!(rendered.html().contains("href=\"#section\""));
        assert!(rendered.html().contains("href=\"https://example.com\""));
        assert!(rendered.html().contains("href=\"mailto:x@y.z\""));
    }

    #[test]
    fn resolves_relative_images_against_the_base_directory() {
        let rendered = render_document("![logo](images/logo.png)", Some(Path::new("/docs/notes")));

        assert!(rendered.html().contains("src=\"/docs/notes/images/logo.png\""));
        assert_eq!(
            rendered.local_images(),
            [PathBuf::from("/docs/notes/images/logo.png")]
        );
    }

    #[test]
    fn resolves_parent_traversal_lexically() {
        let rendered = render_document("![up](../shared/./a.png)", Some(Path::new("/docs/notes")));

        assert!(rendered.html().contains("src=\"/docs/shared/a.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/docs/shared/a.png")]);
    }

    #[test]
    fn clamps_traversal_at_the_root() {
        let rendered = render_document("![x](../../../../etc/a.png)", Some(Path::new("/docs")));

        assert_eq!(rendered.local_images(), [PathBuf::from("/etc/a.png")]);
    }

    #[test]
    fn keeps_absolute_image_paths_and_reports_them() {
        let rendered = render_document("![abs](/pictures/cat.png)", Some(Path::new("/docs")));

        assert!(rendered.html().contains("src=\"/pictures/cat.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/pictures/cat.png")]);
    }

    #[test]
    fn leaves_remote_images_untouched() {
        let markdown = "![a](https://example.com/a.png)\n\n![b](//example.com/b.png)";

        let rendered = render_document(markdown, Some(Path::new("/docs")));

        assert!(rendered.html().contains("src=\"https://example.com/a.png\""));
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn resolves_absolute_images_without_a_base_directory() {
        let rendered = render_document("![abs](/pictures/cat.png)", None);

        assert!(rendered.html().contains("src=\"/pictures/cat.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/pictures/cat.png")]);
    }

    #[test]
    fn leaves_relative_images_untouched_without_a_base_directory() {
        let rendered = render_document("![rel](images/logo.png)", None);

        assert!(rendered.html().contains("src=\"images/logo.png\""));
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn decodes_percent_encoded_image_paths() {
        let rendered = render_document("![shot](my%20shot.png)", Some(Path::new("/docs")));

        assert_eq!(rendered.local_images(), [PathBuf::from("/docs/my shot.png")]);
    }

    #[test]
    fn resolves_raw_html_images_against_the_base_directory() {
        let markdown = "<p align=\"center\">\n  <img src=\"./icon.png\" width=\"128\" alt=\"icon\">\n</p>\n";

        let rendered = render_document(markdown, Some(Path::new("/repo")));

        assert!(rendered.html().contains("src=\"/repo/icon.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/repo/icon.png")]);
    }

    #[test]
    fn keeps_the_align_attribute_on_block_elements() {
        let rendered = render_document(
            "<p align=\"center\"><img src=\"/a.png\"></p>",
            Some(Path::new("/repo")),
        );

        assert!(rendered.html().contains("<p align=\"center\">"));
    }

    #[test]
    fn leaves_remote_raw_html_images_untouched() {
        let rendered = render_document(
            "<img src=\"https://example.com/a.png?x=1&y=2\">",
            Some(Path::new("/repo")),
        );

        assert!(
            rendered
                .html()
                .contains("src=\"https://example.com/a.png?x=1&amp;y=2\"")
        );
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn reports_an_image_used_in_markdown_and_raw_html_once() {
        let markdown = "![a](a.png)\n\n<img src=\"a.png\">\n";

        let rendered = render_document(markdown, Some(Path::new("/repo")));

        assert_eq!(rendered.local_images(), [PathBuf::from("/repo/a.png")]);
    }

    #[test]
    fn render_markdown_keeps_relative_image_sources() {
        let html = render_markdown("![logo](images/logo.png)");

        assert!(html.contains("src=\"images/logo.png\""));
    }

    #[test]
    fn render_document_still_removes_unsafe_html() {
        let markdown = "<script>alert('no')</script>\n\n[bad](javascript:alert('no'))";

        let rendered = render_document(markdown, Some(Path::new("/docs")));

        assert!(!rendered.html().contains("<script"));
        assert!(!rendered.html().contains("javascript:"));
    }

    #[test]
    fn removes_unsafe_html() {
        let markdown = "<script>alert('no')</script>\n\n<img src=x onerror=alert('no')>\n\n[bad](javascript:alert('no'))";

        let html = render_markdown(markdown);

        assert!(!html.contains("<script"));
        assert!(!html.contains("<img"));
        assert!(!html.contains("javascript:"));
        assert!(html.contains("&lt;img"));
    }

    #[test]
    fn highlight_spans_cover_the_core_constructs() {
        let markdown = "# Title\n\nSome *em* and **strong** and `code`.\n\n> quoted\n\n- item\n1. numbered\n\n```\nblock\n```\n\n[link](https://example.com)\n";
        let spans = highlight_spans(markdown);
        let slice = |span: &HighlightSpan| &markdown[span.start as usize..span.end as usize];

        let of = |kind: SpanKind| {
            spans
                .iter()
                .filter(|s| s.kind == kind)
                .map(slice)
                .collect::<Vec<_>>()
        };
        assert_eq!(of(SpanKind::Heading), ["# Title\n"]);
        assert_eq!(of(SpanKind::Emphasis), ["*em*"]);
        assert_eq!(of(SpanKind::Strong), ["**strong**"]);
        assert_eq!(of(SpanKind::CodeSpan), ["`code`"]);
        assert_eq!(of(SpanKind::CodeBlock), ["```\nblock\n```"]);
        assert_eq!(of(SpanKind::Blockquote), ["> quoted\n"]);
        assert_eq!(of(SpanKind::ListMarker), ["-", "1."]);
        assert_eq!(of(SpanKind::Link), ["[link](https://example.com)"]);
    }

    #[test]
    fn highlight_spans_tokenize_fenced_code_with_a_recognized_language() {
        let markdown = "```rust\nfn add(a: i32) -> i32 {\n    a + 41\n}\n```\n";
        let spans = highlight_spans(markdown);
        let slice = |span: &HighlightSpan| &markdown[span.start as usize..span.end as usize];

        let keywords: Vec<_> = spans
            .iter()
            .filter(|s| s.kind == SpanKind::CodeKeyword)
            .map(slice)
            .collect();
        let numbers: Vec<_> = spans
            .iter()
            .filter(|s| s.kind == SpanKind::CodeNumber)
            .map(slice)
            .collect();

        assert!(keywords.contains(&"fn"));
        assert_eq!(numbers, ["41"]);
        // Token spans sit inside the code block's own outer span.
        let block = spans
            .iter()
            .find(|s| s.kind == SpanKind::CodeBlock)
            .expect("code block span");
        for span in &spans {
            if span.kind != SpanKind::CodeBlock {
                assert!(span.start >= block.start && span.end <= block.end);
            }
        }
    }

    #[test]
    fn highlight_spans_skip_tokenizing_fences_without_a_language() {
        let markdown = "```\nplain fence\n```\n";
        let spans = highlight_spans(markdown);

        assert_eq!(spans, [HighlightSpan {
            start: 0,
            end: u32::try_from(markdown.trim_end().len()).unwrap(),
            kind: SpanKind::CodeBlock,
        }]);
    }

    #[test]
    fn highlight_span_offsets_are_utf8_bytes() {
        // "é" is 2 bytes; the strong span must land after them correctly.
        let markdown = "héllo **wörld**";
        let spans = highlight_spans(markdown);
        let strong = spans
            .iter()
            .find(|s| s.kind == SpanKind::Strong)
            .expect("strong span");
        assert_eq!(
            &markdown[strong.start as usize..strong.end as usize],
            "**wörld**"
        );
    }

    #[test]
    fn task_list_markers_highlight_the_checkbox() {
        let markdown = "- [x] done\n- [ ] open\n";
        let spans = highlight_spans(markdown);
        let markers: Vec<_> = spans
            .iter()
            .filter(|s| s.kind == SpanKind::ListMarker)
            .map(|s| &markdown[s.start as usize..s.end as usize])
            .collect();
        assert_eq!(markers, ["-", "[x]", "-", "[ ]"]);
    }

    #[test]
    fn outer_constructs_precede_inner_on_overlap() {
        let markdown = "> a *quoted emphasis*\n";
        let spans = highlight_spans(markdown);
        let quote = spans.iter().position(|s| s.kind == SpanKind::Blockquote);
        let em = spans.iter().position(|s| s.kind == SpanKind::Emphasis);
        assert!(quote.unwrap() < em.unwrap());
    }

    #[test]
    fn allows_structural_html_elements() {
        let markdown = r#"<div class="container">
<figure>
  <img src="image.png" alt="Example">
  <figcaption>A caption</figcaption>
</figure>
<section id="intro">
  <article>Some content</article>
</section>
<details open>
  <summary>Details</summary>
  Hidden content
</details>
</div>"#;

        let html = render_markdown(markdown);

        assert!(html.contains("<div"));
        assert!(html.contains("class=\"container\""));
        assert!(html.contains("<figure"));
        assert!(html.contains("<figcaption>"));
        assert!(html.contains("<section"));
        assert!(html.contains("id=\"intro\""));
        assert!(html.contains("<article>"));
        assert!(html.contains("<details"));
        assert!(html.contains("open"));
        assert!(html.contains("<summary>"));
    }
}
