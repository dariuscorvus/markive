//! Language-aware token classification for code fences, shared by the
//! preview (HTML/CSS classes) and the editor (`SpanKind` colors).
//!
//! `syntect`'s bundled `TextMate` grammars produce scope names (`keyword.
//! control.rs`, `string.quoted.double.js`, ...); [`classify`] collapses
//! them to a small set of [`CodeToken`]s by `TextMate` naming convention,
//! rather than resolving them against a `.tmTheme` — each surface picks
//! its own palette for these tokens instead of inheriting one.

use std::sync::LazyLock;

use syntect::parsing::{ParseState, Scope, ScopeStack, SyntaxSet};
use syntect::util::LinesWithEndings;

static SYNTAX_SET: LazyLock<SyntaxSet> = LazyLock::new(SyntaxSet::load_defaults_newlines);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodeToken {
    Keyword,
    String,
    Comment,
    Number,
    Function,
    Type,
}

/// A classified `[start, end)` byte range within the code block's text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodeSpan {
    pub start: usize,
    pub end: usize,
    pub token: CodeToken,
}

/// Highlights `code` as `language` — a fence info-string token such as
/// `"rust"` or `"js"`, matched against `syntect`'s syntax names,
/// extensions, and first-line tokens. Returns an empty vec when the
/// language isn't recognized; unclassified tokens (operators,
/// punctuation, plain text) are simply omitted from the result.
#[must_use]
pub fn highlight(code: &str, language: &str) -> Vec<CodeSpan> {
    let Some(syntax) = SYNTAX_SET.find_syntax_by_token(language) else {
        return Vec::new();
    };

    let mut parse_state = ParseState::new(syntax);
    let mut stack = ScopeStack::new();
    let mut spans = Vec::new();
    let mut offset = 0usize;

    for line in LinesWithEndings::from(code) {
        let Ok(ops) = parse_state.parse_line(line, &SYNTAX_SET) else {
            break;
        };
        let mut pos = 0usize;
        for (index, op) in ops {
            if index > pos {
                push_token(&mut spans, &stack, offset + pos, offset + index);
                pos = index;
            }
            if stack.apply(&op).is_err() {
                return spans;
            }
        }
        if pos < line.len() {
            push_token(&mut spans, &stack, offset + pos, offset + line.len());
        }
        offset += line.len();
    }

    spans
}

/// Appends a token span, merging into the previous one when it is the
/// same kind and contiguous — a scope push/pop between two spans (e.g.
/// `punctuation.definition.comment` inside `comment.line`) both classify
/// to the same [`CodeToken`] but arrive as separate ranges.
fn push_token(spans: &mut Vec<CodeSpan>, stack: &ScopeStack, start: usize, end: usize) {
    if start >= end {
        return;
    }
    let Some(token) = classify(stack) else { return };

    if let Some(last) = spans.last_mut()
        && last.token == token
        && last.end == start
    {
        last.end = end;
    } else {
        spans.push(CodeSpan { start, end, token });
    }
}

fn classify(stack: &ScopeStack) -> Option<CodeToken> {
    stack
        .as_slice()
        .iter()
        .rev()
        .find_map(|scope| classify_scope(*scope))
}

fn classify_scope(scope: Scope) -> Option<CodeToken> {
    let name = scope.build_string();
    if name.starts_with("comment") {
        Some(CodeToken::Comment)
    } else if name.starts_with("string") {
        Some(CodeToken::String)
    } else if name.starts_with("constant.numeric") {
        Some(CodeToken::Number)
    } else if name.starts_with("entity.name.function") || name.starts_with("support.function") {
        Some(CodeToken::Function)
    } else if name.starts_with("entity.name.type")
        || name.starts_with("entity.name.class")
        || name.starts_with("entity.other.inherited-class")
        || name.starts_with("support.type")
        || name.starts_with("support.class")
    {
        Some(CodeToken::Type)
    } else if (name.starts_with("keyword") && !name.starts_with("keyword.operator"))
        || name.starts_with("storage.type")
        || name.starts_with("storage.modifier")
        || name.starts_with("constant.language")
    {
        Some(CodeToken::Keyword)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens_of<'a>(code: &'a str, language: &str, wanted: CodeToken) -> Vec<&'a str> {
        highlight(code, language)
            .into_iter()
            .filter(|span| span.token == wanted)
            .map(|span| &code[span.start..span.end])
            .collect()
    }

    #[test]
    fn classifies_rust_keywords_strings_comments_and_numbers() {
        let code = "// a comment\nfn add(a: i32) -> i32 {\n    a + 41\n}\n";

        assert_eq!(tokens_of(code, "rust", CodeToken::Comment), ["// a comment\n"]);
        assert!(tokens_of(code, "rust", CodeToken::Keyword).contains(&"fn"));
        assert_eq!(tokens_of(code, "rust", CodeToken::Number), ["41"]);
    }

    #[test]
    fn classifies_string_literals() {
        let code = "console.log(\"hi\");\n";

        assert_eq!(tokens_of(code, "js", CodeToken::String), ["\"hi\""]);
    }

    #[test]
    fn unrecognized_language_yields_no_spans() {
        assert!(highlight("whatever", "not-a-real-language").is_empty());
    }

    #[test]
    fn offsets_are_byte_ranges_into_the_original_code() {
        let code = "let café = 1;\n";
        let spans = highlight(code, "rust");

        for span in &spans {
            assert!(code.is_char_boundary(span.start));
            assert!(code.is_char_boundary(span.end));
        }
    }
}
