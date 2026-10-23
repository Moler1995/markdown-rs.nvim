//! `docs/md-render-format.md` is normative for anyone reading the engine's
//! output, so its worked example has to be the engine's real output rather
//! than a plausible-looking transcription of it.
//!
//! This test extracts the example from the document and renders the same input
//! itself, then compares the two. When the format changes, the document fails
//! to build — which is the point: a reader following a stale document is worse
//! off than one following none.

use md_render::document::{layout_document, source_line_count};
use md_render::image_art::ImageOptions;
use md_render::renderer::render_markdown;
use md_render::theme::{Palette, Theme};

const FORMAT_DOC: &str = include_str!("../../docs/md-render-format.md");

/// The input the document's example claims to be rendering.
const DOC_INPUT: &str = "# Hi\n\nplain **bold** text\n";
/// The width the document's example claims to have rendered at.
const DOC_WIDTH: u16 = 40;

/// Pull the single fenced `json` block out of the format document.
fn example_json() -> serde_json::Value {
    // The document is checked out with CRLF on Windows; fenced-block
    // detection must not depend on the line ending.
    let document = FORMAT_DOC.replace("\r\n", "\n");
    let start = document
        .find("```json\n")
        .expect("the format document must contain a ```json block")
        + "```json\n".len();
    let rest = &document[start..];
    let end = rest
        .find("\n```")
        .expect("the document's ```json block must be closed");
    serde_json::from_str(&rest[..end]).expect("the document's example must be valid JSON")
}

fn render(input: &str, width: u16) -> serde_json::Value {
    let palette = Palette::from_theme(Theme::default());
    let blocks = render_markdown(input, &palette, Theme::default());
    let doc = layout_document(
        &blocks,
        width,
        &palette,
        source_line_count(input),
        ImageOptions::default(),
    );
    serde_json::to_value(&doc).expect("the engine's own output must serialise")
}

#[test]
fn the_documented_example_is_the_engines_real_output() {
    let documented = example_json();
    let real = render(DOC_INPUT, DOC_WIDTH);
    assert_eq!(
        documented, real,
        "the example in docs/md-render-format.md no longer matches what the \
         engine produces for {DOC_INPUT:?} at width {DOC_WIDTH}. Update the \
         document."
    );
}

#[test]
fn the_documented_top_level_fields_are_the_ones_emitted() {
    let documented = example_json();
    let real = render(DOC_INPUT, DOC_WIDTH);

    let documented_keys: Vec<&String> = documented
        .as_object()
        .expect("the example must be an object")
        .keys()
        .collect();
    let real_keys: Vec<&String> = real
        .as_object()
        .expect("the output must be an object")
        .keys()
        .collect();

    assert_eq!(
        documented_keys, real_keys,
        "the document must name every top-level field the engine emits, and no others"
    );
    for expected in ["version", "width", "styles", "lines", "source_map"] {
        assert!(
            real_keys.iter().any(|k| k.as_str() == expected),
            "the wire format must carry `{expected}`"
        );
    }
}

#[test]
fn every_line_carries_source_and_spans_plus_optional_links() {
    let real = render(DOC_INPUT, DOC_WIDTH);
    for (i, line) in real["lines"]
        .as_array()
        .expect("lines must be an array")
        .iter()
        .enumerate()
    {
        let keys: Vec<&str> = line
            .as_object()
            .unwrap_or_else(|| panic!("line {i} must be an object"))
            .keys()
            .map(String::as_str)
            .collect();
        for key in &keys {
            assert!(
                matches!(*key, "source" | "spans" | "links"),
                "line {i} has an undocumented field `{key}`: {keys:?}"
            );
        }
        assert!(keys.contains(&"source"), "line {i} lacks `source`");
        assert!(keys.contains(&"spans"), "line {i} lacks `spans`");
        assert!(
            !keys.contains(&"links"),
            "line {i} carries `links` although the documented example has no \
             clickable runs — the field must be omitted when empty"
        );
    }
}

#[test]
fn a_span_is_a_style_index_and_a_string() {
    let real = render(DOC_INPUT, DOC_WIDTH);
    let style_count = real["styles"]
        .as_array()
        .expect("styles must be an array")
        .len();

    for (i, line) in real["lines"].as_array().expect("lines").iter().enumerate() {
        for span in line["spans"].as_array().expect("spans must be an array") {
            let pair = span.as_array().expect("a span must be a two-element array");
            assert_eq!(pair.len(), 2, "span {span} in line {i} is not a pair");
            let index = pair[0]
                .as_u64()
                .expect("a span's first element is an index");
            assert!(
                (index as usize) < style_count,
                "line {i} references style {index}, but only {style_count} are defined"
            );
            assert!(pair[1].is_string(), "a span's second element is its text");
        }
    }
}

#[test]
fn every_style_always_carries_fg_and_bg() {
    let real = render(DOC_INPUT, DOC_WIDTH);
    for (i, style) in real["styles"]
        .as_array()
        .expect("styles must be an array")
        .iter()
        .enumerate()
    {
        let object = style.as_object().expect("a style must be an object");
        assert!(object.contains_key("fg"), "style {i} has no `fg`");
        assert!(object.contains_key("bg"), "style {i} has no `bg`");
        for key in object.keys() {
            assert!(
                matches!(
                    key.as_str(),
                    "fg" | "bg"
                        | "bold"
                        | "dim"
                        | "italic"
                        | "underline"
                        | "strikethrough"
                        | "reverse"
                ),
                "style {i} carries an undocumented field `{key}`"
            );
        }
    }
}

#[test]
fn source_map_is_one_valid_index_per_source_line() {
    let real = render(DOC_INPUT, DOC_WIDTH);
    let line_count = real["lines"].as_array().expect("lines").len();
    let map = real["source_map"]
        .as_array()
        .expect("source_map must be an array");

    assert_eq!(
        map.len(),
        source_line_count(DOC_INPUT),
        "source_map must have one entry per source line"
    );
    for (i, entry) in map.iter().enumerate() {
        let index = entry
            .as_u64()
            .unwrap_or_else(|| panic!("source_map[{i}] must be an index"))
            as usize;
        assert!(
            index < line_count,
            "source_map[{i}] is {index}, but there are only {line_count} lines"
        );
    }
}

/// A mermaid `click` directive must reach the wire as a byte range on the
/// label — not as the terminal's OSC 8 escape bytes, which an editor buffer
/// would show literally.
#[test]
fn a_click_directive_reaches_the_wire_as_a_byte_range() {
    const CLICK_INPUT: &str = "\
```mermaid
graph LR
  A[Alpha] --> B[Beta]
  click A href \"linked.md\" \"Alpha\"
```
";
    let real = render(CLICK_INPUT, 80);

    let lines = real["lines"].as_array().expect("lines must be an array");
    let line = lines
        .iter()
        .find(|line| line.get("links").is_some())
        .expect("the clicked node's row must carry `links`");

    let text: String = line["spans"]
        .as_array()
        .expect("spans")
        .iter()
        .map(|span| span[1].as_str().expect("span text"))
        .collect();
    assert!(
        !text.contains('\x1b'),
        "terminal escapes must never reach the buffer: {text:?}"
    );

    let link = &line["links"].as_array().expect("links")[0];
    let pair = link.as_array().expect("a link must be an array");
    assert_eq!(pair.len(), 3, "a link is `[start, end, target]`");
    assert_eq!(pair[2], "linked.md", "the target must survive verbatim");

    let start = pair[0].as_u64().expect("start") as usize;
    let end = pair[1].as_u64().expect("end") as usize;
    assert_eq!(
        &text[start..end],
        "Alpha",
        "the range must cover exactly the label"
    );
}
