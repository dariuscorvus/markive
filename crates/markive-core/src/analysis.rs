use std::collections::BTreeSet;
use std::sync::OnceLock;

use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use regex::Regex;
use serde::Serialize;
use serde_yaml_ng::Value;

use crate::markdown_options;

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentAnalysis {
    pub headings: Vec<HeadingAnalysis>,
    pub links: Vec<LinkAnalysis>,
    pub properties: Vec<PropertyAnalysis>,
    pub aliases: Vec<String>,
    pub tags: Vec<String>,
    pub tasks: Vec<TaskAnalysis>,
    pub frontmatter_error: Option<String>,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeadingAnalysis {
    pub level: u8,
    pub text: String,
    pub slug: String,
    pub line: usize,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkAnalysis {
    pub kind: LinkKind,
    pub target: String,
    pub heading: Option<String>,
    pub display: String,
    pub line: usize,
    pub column: usize,
    pub utf16_location: usize,
    pub utf16_length: usize,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkKind {
    Markdown,
    Wikilink,
    Embed,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PropertyAnalysis {
    pub name: String,
    pub kind: PropertyKind,
    pub display_value: String,
    pub values: Vec<String>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PropertyKind {
    Text,
    List,
    Number,
    Checkbox,
    Date,
    Object,
    Empty,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskAnalysis {
    pub text: String,
    pub completed: bool,
    pub line: usize,
}

struct Frontmatter<'a> {
    yaml: Option<&'a str>,
    body_start: usize,
    error: Option<String>,
}

/// Parses the knowledge-bearing parts of one Markdown document without
/// changing its source. The JSON representation is the stable FFI boundary
/// used by the native app's disposable workspace index.
#[must_use]
pub fn analyze_document(markdown: &str) -> DocumentAnalysis {
    let frontmatter = split_frontmatter(markdown);
    let (properties, yaml_error) = match frontmatter.yaml {
        Some(yaml) => parse_properties(yaml),
        None => (Vec::new(), None),
    };

    let aliases = property_values(&properties, "aliases");
    let mut tags: BTreeSet<String> = property_values(&properties, "tags")
        .into_iter()
        .map(|tag| tag.trim_start_matches('#').to_owned())
        .filter(|tag| !tag.is_empty())
        .collect();

    let code_ranges = code_ranges(markdown);
    let mut links = markdown_links(markdown, frontmatter.body_start, &code_ranges);
    links.extend(wikilinks(markdown, frontmatter.body_start, &code_ranges));
    links.sort_by_key(|link| link.utf16_location);

    for capture in tag_regex().captures_iter(&markdown[frontmatter.body_start..]) {
        let Some(tag_match) = capture.get(1) else {
            continue;
        };
        let byte_offset = frontmatter.body_start + tag_match.start();
        if !is_in_ranges(byte_offset, &code_ranges) {
            tags.insert(
                tag_match
                    .as_str()
                    .trim_end_matches(['.', ',', ';', ':', '!', '?'])
                    .to_owned(),
            );
        }
    }

    DocumentAnalysis {
        headings: headings(markdown, frontmatter.body_start),
        links,
        properties,
        aliases,
        tags: tags.into_iter().collect(),
        tasks: tasks(markdown, frontmatter.body_start, &code_ranges),
        frontmatter_error: frontmatter.error.or(yaml_error),
    }
}

/// Serializes [`analyze_document`] for the C ABI. Serialization only contains
/// owned strings, numbers, booleans, and arrays, so failure indicates a bug.
#[must_use]
pub fn analyze_document_json(markdown: &str) -> String {
    serde_json::to_string(&analyze_document(markdown)).unwrap_or_default()
}

fn split_frontmatter(markdown: &str) -> Frontmatter<'_> {
    let Some(first_newline) = markdown.find('\n') else {
        return Frontmatter {
            yaml: None,
            body_start: 0,
            error: None,
        };
    };
    if markdown[..first_newline].trim_end_matches('\r') != "---" {
        return Frontmatter {
            yaml: None,
            body_start: 0,
            error: None,
        };
    }

    let mut offset = first_newline + 1;
    for line in markdown[offset..].split_inclusive('\n') {
        if line.trim_end_matches(['\r', '\n']) == "---" {
            let yaml_end = offset;
            let body_start = offset + line.len();
            return Frontmatter {
                yaml: Some(&markdown[first_newline + 1..yaml_end]),
                body_start,
                error: None,
            };
        }
        offset += line.len();
    }

    Frontmatter {
        yaml: None,
        body_start: markdown.len(),
        error: Some("Frontmatter starts on line 1 but has no closing --- delimiter.".to_owned()),
    }
}

fn parse_properties(yaml: &str) -> (Vec<PropertyAnalysis>, Option<String>) {
    let value = match serde_yaml_ng::from_str::<Value>(yaml) {
        Ok(value) => value,
        Err(error) => {
            return (
                Vec::new(),
                Some(format!("Invalid YAML frontmatter: {error}")),
            );
        }
    };
    let Value::Mapping(mapping) = value else {
        return (
            Vec::new(),
            Some("Frontmatter must be a YAML mapping of property names to values.".to_owned()),
        );
    };

    let mut properties = Vec::with_capacity(mapping.len());
    for (key, value) in mapping {
        let Some(name) = scalar_string(&key) else {
            return (
                Vec::new(),
                Some("Frontmatter property names must be strings.".to_owned()),
            );
        };
        let (kind, display_value, values) = property_value(&value);
        properties.push(PropertyAnalysis {
            name,
            kind,
            display_value,
            values,
        });
    }
    (properties, None)
}

fn property_value(value: &Value) -> (PropertyKind, String, Vec<String>) {
    match value {
        Value::Null => (PropertyKind::Empty, String::new(), Vec::new()),
        Value::Bool(value) => (
            PropertyKind::Checkbox,
            value.to_string(),
            vec![value.to_string()],
        ),
        Value::Number(value) => (
            PropertyKind::Number,
            value.to_string(),
            vec![value.to_string()],
        ),
        Value::String(value) => {
            let kind = if date_regex().is_match(value) {
                PropertyKind::Date
            } else {
                PropertyKind::Text
            };
            (kind, value.clone(), vec![value.clone()])
        }
        Value::Sequence(values) => {
            let flattened: Vec<String> = values.iter().filter_map(scalar_string).collect();
            (PropertyKind::List, flattened.join(", "), flattened)
        }
        Value::Mapping(_) | Value::Tagged(_) => {
            let display = serde_yaml_ng::to_string(value)
                .unwrap_or_default()
                .trim()
                .to_owned();
            (PropertyKind::Object, display.clone(), vec![display])
        }
    }
}

fn scalar_string(value: &Value) -> Option<String> {
    match value {
        Value::Null => Some(String::new()),
        Value::Bool(value) => Some(value.to_string()),
        Value::Number(value) => Some(value.to_string()),
        Value::String(value) => Some(value.clone()),
        _ => None,
    }
}

fn property_values(properties: &[PropertyAnalysis], name: &str) -> Vec<String> {
    properties
        .iter()
        .find(|property| property.name.eq_ignore_ascii_case(name))
        .map(|property| property.values.clone())
        .unwrap_or_default()
}

fn headings(markdown: &str, body_start: usize) -> Vec<HeadingAnalysis> {
    let mut output = Vec::new();
    let mut pending: Option<(u8, usize, String)> = None;

    for (event, range) in
        Parser::new_ext(&markdown[body_start..], markdown_options()).into_offset_iter()
    {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                pending = Some((level as u8, body_start + range.start, String::new()));
            }
            Event::Text(text) | Event::Code(text) if pending.is_some() => {
                if let Some((_, _, heading)) = pending.as_mut() {
                    heading.push_str(&text);
                }
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some((level, offset, text)) = pending.take() {
                    output.push(HeadingAnalysis {
                        level,
                        slug: crate::slugify(&text),
                        text,
                        line: line_and_column(markdown, offset).0,
                    });
                }
            }
            _ => {}
        }
    }
    output
}

fn markdown_links(
    markdown: &str,
    body_start: usize,
    code_ranges: &[std::ops::Range<usize>],
) -> Vec<LinkAnalysis> {
    markdown_link_regex()
        .captures_iter(markdown)
        .filter_map(|capture| {
            let whole = capture.get(0)?;
            if whole.as_str().starts_with('!')
                || whole.start() < body_start
                || is_in_ranges(whole.start(), code_ranges)
            {
                return None;
            }
            let display = capture.get(1)?.as_str().to_owned();
            let destination = capture.get(2)?.as_str();
            let (target, heading) = split_target(destination);
            let (line, column) = line_and_column(markdown, whole.start());
            let (utf16_location, utf16_length) = utf16_range(markdown, whole.start(), whole.end());
            Some(LinkAnalysis {
                kind: LinkKind::Markdown,
                target,
                heading,
                display,
                line,
                column,
                utf16_location,
                utf16_length,
            })
        })
        .collect()
}

fn wikilinks(
    markdown: &str,
    body_start: usize,
    code_ranges: &[std::ops::Range<usize>],
) -> Vec<LinkAnalysis> {
    wikilink_regex()
        .captures_iter(&markdown[body_start..])
        .filter_map(|capture| {
            let whole = capture.get(0)?;
            let start = body_start + whole.start();
            let end = body_start + whole.end();
            if is_in_ranges(start, code_ranges) {
                return None;
            }
            let inner = capture.get(2)?.as_str();
            let mut parts = inner.splitn(2, '|');
            let destination = parts.next()?.trim();
            let alias = parts.next().map(str::trim);
            let (target, heading) = split_target(destination);
            let display = alias.map_or_else(
                || heading.clone().unwrap_or_else(|| target.clone()),
                str::to_owned,
            );
            let (line, column) = line_and_column(markdown, start);
            let (utf16_location, utf16_length) = utf16_range(markdown, start, end);
            Some(LinkAnalysis {
                kind: if capture.get(1).is_some() {
                    LinkKind::Embed
                } else {
                    LinkKind::Wikilink
                },
                target,
                heading,
                display,
                line,
                column,
                utf16_location,
                utf16_length,
            })
        })
        .collect()
}

fn split_target(destination: &str) -> (String, Option<String>) {
    let destination = destination.trim();
    if let Some((target, heading)) = destination.split_once('#') {
        (
            target.trim().to_owned(),
            (!heading.trim().is_empty()).then(|| heading.trim().to_owned()),
        )
    } else {
        (destination.to_owned(), None)
    }
}

fn tasks(
    markdown: &str,
    body_start: usize,
    code_ranges: &[std::ops::Range<usize>],
) -> Vec<TaskAnalysis> {
    task_regex()
        .captures_iter(&markdown[body_start..])
        .filter_map(|capture| {
            let whole = capture.get(0)?;
            let offset = body_start + whole.start();
            if is_in_ranges(offset, code_ranges) {
                return None;
            }
            Some(TaskAnalysis {
                completed: capture
                    .get(1)
                    .is_some_and(|marker| marker.as_str().eq_ignore_ascii_case("x")),
                text: capture.get(2)?.as_str().trim().to_owned(),
                line: line_and_column(markdown, offset).0,
            })
        })
        .collect()
}

fn code_ranges(markdown: &str) -> Vec<std::ops::Range<usize>> {
    Parser::new_ext(markdown, markdown_options())
        .into_offset_iter()
        .filter_map(|(event, range)| {
            matches!(event, Event::Start(Tag::CodeBlock(_)) | Event::Code(_)).then_some(range)
        })
        .collect()
}

fn is_in_ranges(offset: usize, ranges: &[std::ops::Range<usize>]) -> bool {
    ranges.iter().any(|range| range.contains(&offset))
}

fn line_and_column(markdown: &str, byte_offset: usize) -> (usize, usize) {
    let prefix = &markdown[..byte_offset];
    let line = prefix.bytes().filter(|byte| *byte == b'\n').count() + 1;
    let line_start = prefix.rfind('\n').map_or(0, |index| index + 1);
    let column = markdown[line_start..byte_offset].chars().count() + 1;
    (line, column)
}

fn utf16_range(markdown: &str, start: usize, end: usize) -> (usize, usize) {
    let location = markdown[..start].encode_utf16().count();
    let length = markdown[start..end].encode_utf16().count();
    (location, length)
}

fn markdown_link_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r#"(?m)(?:!)?\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)"#)
            .expect("valid Markdown link regex")
    })
}

fn wikilink_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"(!)?\[\[([^\]\n]+)\]\]").expect("valid wikilink regex"))
}

fn tag_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?:^|[[:space:]])#([\p{L}\p{N}_/-]+)").expect("valid tag regex")
    })
}

fn task_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?m)^[[:space:]]*[-*+][[:space:]]+\[([ xX])\][[:space:]]*(.*)$")
            .expect("valid task regex")
    })
}

fn date_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"^\d{4}-\d{2}-\d{2}(?:[T ][^\s]+)?$").expect("valid date regex")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn analyzes_links_metadata_tags_tasks_and_headings() {
        let markdown = r#"---
title: "Project Alpha"
aliases:
  - Alpha
tags: [work, active]
status: draft
reviewed: 2026-07-29
published: false
weight: 42
---
# Project Alpha

See [[Notes/Source#Details|the source]] and [standard](Other.md).

#inline/tag

- [ ] Follow up
- [x] Captured

`[[not a link]]`
"#;
        let analysis = analyze_document(markdown);

        assert_eq!(analysis.headings[0].text, "Project Alpha");
        assert_eq!(analysis.links.len(), 2);
        assert_eq!(analysis.links[0].target, "Notes/Source");
        assert_eq!(analysis.links[0].heading.as_deref(), Some("Details"));
        assert_eq!(analysis.links[0].display, "the source");
        assert_eq!(analysis.aliases, ["Alpha"]);
        assert_eq!(analysis.tags, ["active", "inline/tag", "work"]);
        assert_eq!(analysis.tasks.len(), 2);
        assert!(!analysis.tasks[0].completed);
        assert!(analysis.tasks[1].completed);
        assert!(analysis.frontmatter_error.is_none());
        assert_eq!(
            analysis
                .properties
                .iter()
                .find(|property| property.name == "published")
                .map(|property| property.kind),
            Some(PropertyKind::Checkbox)
        );
    }

    #[test]
    fn reports_invalid_frontmatter_without_losing_body_analysis() {
        let markdown = "---\ntags: [one\n---\n# Still indexed\n";
        let analysis = analyze_document(markdown);

        assert!(analysis.frontmatter_error.is_some());
        assert_eq!(analysis.headings[0].text, "Still indexed");
    }

    #[test]
    fn analysis_json_is_stable_camel_case() {
        let json = analyze_document_json("# Heading\n\n[[Target]]");

        assert!(json.contains("\"frontmatterError\":null"));
        assert!(json.contains("\"utf16Location\""));
        assert!(json.contains("\"kind\":\"wikilink\""));
    }
}
