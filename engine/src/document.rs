//! Laying rendered blocks out into wire lines.
//!
//! [`crate::renderer`] decides *what* a document contains: which lines are
//! headings, where the tables are, which fenced blocks are diagrams.
//! [`layout_document`] decides *how wide* each of those is — it is the only
//! place that knows the target width, and the only place that turns blocks
//! into the flat line list the plugin receives.
//!
//! Every line leaving this module has passed through [`wrap_spans`] at the
//! target width, which is what makes the engine's width guarantee hold for
//! content the block renderers did not measure themselves — notably diagram
//! artwork, whose layout is a best-effort compaction rather than a hard
//! constraint.

use unicode_width::UnicodeWidthStr;

use crate::block::DocBlock;
use crate::mermaid::{MermaidTextBackend, render_text};
use crate::style::{Line, Span, Style};
use crate::table::layout_table;
use crate::text_layout::wrap_spans;
use crate::theme::Palette;
use crate::wire::{StyleTable, WIRE_VERSION, WireDoc, WireLine, build_source_map};

/// Lay out every block for `width` columns and produce the document the plugin
/// receives.
///
/// `source_line_count` is the number of lines in the source document — the
/// length `source_map` is built to, and the bound every emitted source anchor
/// is clamped to.
#[must_use]
pub fn layout_document(
    blocks: &[DocBlock],
    width: u16,
    palette: &Palette,
    source_line_count: usize,
) -> WireDoc {
    let mut layout = Layout::new(width, palette, source_line_count);

    for block in blocks {
        match block {
            DocBlock::Text { text, source_lines } => {
                for (i, line) in text.lines.iter().enumerate() {
                    let source = source_lines.get(i).copied();
                    layout.push(source, line);
                }
            }
            DocBlock::Table(table) => {
                let (text, _height, physical_to_source) = layout_table(table, width, palette);
                for (i, line) in text.lines.iter().enumerate() {
                    // `None` here is a border: artwork with no source line of
                    // its own. It stays `None` on the wire, and the plugin
                    // resolves it to the enclosing table's first source line.
                    let source = physical_to_source.get(i).copied().flatten();
                    layout.push(source, line);
                }
            }
            DocBlock::Mermaid { source, source_line } => {
                layout.push_mermaid(source, *source_line);
            }
        }
    }

    // An empty document renders to no lines at all, but a buffer is never
    // zero lines — the editor shows one blank one. Emitting it here keeps
    // `source_map` total, so a lookup for source line 0 always resolves.
    if layout.lines.is_empty() {
        layout.push(Some(0), &Line::new());
    }

    let lines = layout.lines;
    let source_map = build_source_map(&lines, source_line_count);

    WireDoc {
        version: WIRE_VERSION,
        width,
        styles: layout.styles.into_styles(),
        lines,
        source_map,
    }
}

/// Accumulates laid-out lines, interning styles and clamping source anchors as
/// it goes.
struct Layout<'a> {
    width: u16,
    palette: &'a Palette,
    /// The highest source line a display line may claim, so a renderer that
    /// runs one line past the end of the document cannot emit an anchor the
    /// plugin would index out of range.
    max_source: u32,
    styles: StyleTable,
    lines: Vec<WireLine>,
}

impl<'a> Layout<'a> {
    fn new(width: u16, palette: &'a Palette, source_line_count: usize) -> Layout<'a> {
        Layout {
            width,
            palette,
            max_source: crate::cast::u32_sat(source_line_count.saturating_sub(1)),
            styles: StyleTable::new(),
            lines: Vec::new(),
        }
    }

    /// Wrap `line` to the target width and append the result.
    ///
    /// A line that already fits is emitted unchanged; one that does not is
    /// split, so no caller has to be trusted to respect the width itself.
    fn push(&mut self, source: Option<u32>, line: &Line) {
        let source = source.map(|s| s.min(self.max_source));
        for wrapped in wrap_spans(&line.spans, self.width) {
            let line = wrapped.to_line();
            self.lines.push(self.styles.line(source, &line));
        }
    }

    /// Append the display lines for a mermaid block.
    ///
    /// The artwork is attributed to the fence line. The spec's cursor scenario
    /// calls diagram artwork synthetic and asks that a synthetic line resolve
    /// to "the source line of the construct that produced it" — and the fence
    /// line *is* that construct, so naming it directly is both simpler and
    /// more accurate than marking the artwork synthetic and leaving the plugin
    /// to guess by scanning.
    ///
    /// When the diagram cannot be rendered the source is shown as-is, one
    /// display line per source line, so the reader sees what they wrote and
    /// the cursor lands where they expect.
    fn push_mermaid(&mut self, source: &str, source_line: u32) {
        let source_line = source_line.min(self.max_source);
        let art_style = Style::default().fg(self.palette.foreground);

        match render_text(source, Some(self.width as usize), MermaidTextBackend::Auto) {
            Ok(art) => {
                for line in art.lines() {
                    self.push(Some(source_line), &Line::from(Span::styled(line, art_style)));
                }
            }
            Err(_) => {
                for (i, line) in source.lines().enumerate() {
                    let line_source = source_line.saturating_add(1).saturating_add(
                        crate::cast::u32_sat(i),
                    );
                    self.push(Some(line_source), &Line::from(Span::styled(line, art_style)));
                }
            }
        }
    }
}

/// The number of source lines `content` occupies.
///
/// This matches the line count the editor reports for the same text, which is
/// what the plugin indexes `source_map` with: a trailing newline terminates the
/// last line rather than starting a new one, and an empty document is one empty
/// line rather than none.
#[must_use]
pub fn source_line_count(content: &str) -> usize {
    content.lines().count().max(1)
}

/// The display width of a laid-out line, for the width-guarantee check.
#[must_use]
pub fn display_width(line: &WireLine) -> usize {
    line.spans
        .iter()
        .map(|span| UnicodeWidthStr::width(span.1.as_str()))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::markdown_options;
    use crate::renderer::render_markdown;
    use crate::theme::{Palette, Theme};

    fn layout(content: &str, width: u16) -> WireDoc {
        let palette = Palette::default();
        let blocks = render_markdown(content, &palette, Theme::default());
        layout_document(&blocks, width, &palette, source_line_count(content))
    }

    #[test]
    fn source_line_count_matches_the_editors_view() {
        assert_eq!(source_line_count(""), 1);
        assert_eq!(source_line_count("a"), 1);
        assert_eq!(source_line_count("a\nb"), 2);
        // A trailing newline terminates the last line rather than starting a
        // new one — the editor shows two lines here, not three.
        assert_eq!(source_line_count("a\nb\n"), 2);
    }

    #[test]
    fn a_long_paragraph_wraps_and_keeps_its_source_line() {
        let paragraph = "word ".repeat(60);
        let doc = layout(&paragraph, 40);

        let content_lines: Vec<&WireLine> = doc
            .lines
            .iter()
            .filter(|l| !l.spans.is_empty())
            .collect();
        assert!(
            content_lines.len() > 1,
            "a 300-column paragraph must occupy several lines at width 40"
        );
        for line in &content_lines {
            assert!(
                display_width(line) <= 40,
                "line of width {} exceeds the requested 40",
                display_width(line)
            );
            assert_eq!(
                line.source,
                Some(0),
                "every line of a one-source-line paragraph anchors to line 0"
            );
        }
    }

    #[test]
    fn source_map_length_equals_the_document_line_count() {
        let content = "# Title\n\nSome text here.\n\n- a\n- b\n";
        let doc = layout(content, 60);
        assert_eq!(doc.source_map.len(), source_line_count(content));
        for &entry in &doc.source_map {
            assert!(
                (entry as usize) < doc.lines.len(),
                "source_map entry {entry} is not a valid index into {} lines",
                doc.lines.len()
            );
        }
    }

    #[test]
    fn every_line_anchor_is_a_real_source_line() {
        let content = "# H\n\npara\n\n```rust\nlet x = 1;\n```\n\n```mermaid\ngraph LR\n A-->B\n```\n";
        let doc = layout(content, 60);
        let count = source_line_count(content) as u32;
        for (i, line) in doc.lines.iter().enumerate() {
            if let Some(source) = line.source {
                assert!(
                    source < count,
                    "line {i} claims source line {source}, but the document has {count}"
                );
            }
        }
    }

    #[test]
    fn a_table_renders_within_the_width_and_maps_to_its_rows() {
        let content = "| Name | Description |\n|---|---|\n| a | first row |\n| b | second row |\n";
        let doc = layout(content, 40);

        for line in &doc.lines {
            assert!(
                display_width(line) <= 40,
                "table line of width {} exceeds the requested 40",
                display_width(line)
            );
        }

        // The border above the header is artwork, and the plugin resolves it
        // to the table's first source line.
        assert_eq!(doc.lines[0].source, None, "the top border is synthetic");

        // Both body rows are reachable: source line 2 and source line 3 must
        // each have a display line pointing at them.
        let sources: Vec<Option<u32>> = doc.lines.iter().map(|l| l.source).collect();
        assert!(
            sources.contains(&Some(2)),
            "no display line is anchored to the first body row (source line 2): {sources:?}"
        );
        assert!(
            sources.contains(&Some(3)),
            "no display line is anchored to the second body row (source line 3): {sources:?}"
        );
    }

    #[test]
    fn a_mermaid_block_renders_as_artwork_anchored_to_its_fence() {
        let content = "intro\n\n```mermaid\ngraph LR\n  A --> B\n```\n";
        let doc = layout(content, 60);

        // The fence is source line 2 (0-indexed).
        let fence = 2u32;
        let artwork: Vec<&WireLine> = doc
            .lines
            .iter()
            .filter(|l| l.source == Some(fence) && !l.spans.is_empty())
            .collect();
        assert!(
            !artwork.is_empty(),
            "the diagram's artwork must be anchored to its fence line"
        );
        for line in &doc.lines {
            assert!(display_width(line) <= 60);
        }
    }

    #[test]
    fn an_unrenderable_diagram_falls_back_to_its_source() {
        let content = "```mermaid\nthis is not a diagram\n```\n";
        let doc = layout(content, 60);

        let text: String = doc
            .lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.1.as_str())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            text.contains("this is not a diagram"),
            "an unrenderable diagram must fall back to showing its source, got: {text:?}"
        );
    }

    #[test]
    fn display_math_renders_as_text_within_the_width() {
        let content = "$$\n\\frac{a}{b} = c\n$$\n";
        let doc = layout(content, 60);
        assert!(!doc.lines.is_empty(), "a display-math block must produce lines");
        for line in &doc.lines {
            assert!(display_width(line) <= 60);
        }
        let text: String = doc
            .lines
            .iter()
            .flat_map(|l| l.spans.iter().map(|s| s.1.as_str()))
            .collect();
        assert!(
            text.contains('a') && text.contains('b'),
            "the formula's operands must survive into the output: {text:?}"
        );
    }

    #[test]
    fn every_line_fits_every_width_in_the_corpus() {
        let corpus = [
            "# Heading\n\nA paragraph that is comfortably long enough to need wrapping at the narrower widths used by this test.\n",
            "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n",
            "```rust\nfn main() { println!(\"hello, world\"); }\n```\n",
            "```mermaid\ngraph LR\n  A[Start] --> B[End]\n```\n",
            "- one\n- two\n  - nested\n\n> quoted text\n\n---\n",
            "Text with `inline code`, **bold**, *italic* and [a link](https://example.com/very/long/path).\n",
            "$$\nE = mc^2\n$$\n",
        ];

        for content in corpus {
            for width in [20u16, 40, 100] {
                let doc = layout(content, width);
                for (i, line) in doc.lines.iter().enumerate() {
                    assert!(
                        display_width(line) <= width as usize,
                        "at width {width}, line {i} is {} columns wide in:\n{content}",
                        display_width(line)
                    );
                }
            }
        }
    }

    #[test]
    fn rendering_twice_at_the_same_width_is_byte_identical() {
        let content = "# H\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```rust\nlet x = 1;\n```\n";
        let first = serde_json::to_string(&layout(content, 80)).expect("serialise");
        let second = serde_json::to_string(&layout(content, 80)).expect("serialise");
        assert_eq!(first, second);
    }

    #[test]
    fn the_document_echoes_its_version_and_width() {
        let doc = layout("# H\n", 72);
        assert_eq!(doc.version, WIRE_VERSION);
        assert_eq!(doc.width, 72);
    }

    #[test]
    fn an_empty_document_still_produces_a_well_formed_result() {
        let doc = layout("", 80);
        assert_eq!(doc.source_map.len(), 1);
        // `markdown_options` is exercised here too: an empty document must not
        // panic through the parser.
        assert!(markdown_options().contains(pulldown_cmark::Options::ENABLE_TABLES));
    }
}
