//! Laying rendered blocks out into wire lines.
//!
//! [`crate::renderer`] decides *what* a document contains: which lines are
//! headings, where the tables are, which fenced blocks are diagrams.
//! [`layout_document`] decides *how wide* each of those is — it is the only
//! place that knows the target width, and the only place that turns blocks
//! into the flat line list the plugin receives.
//!
//! Every line leaving this module fits the target width, which is what makes
//! the engine's width guarantee hold for content the block renderers did not
//! measure themselves. Prose and tables get there by [`wrap_spans`], which
//! breaks a line into several; diagram artwork gets there by [`clip_to_width`],
//! which drops the right edge, because half a diagram row is worth less than a
//! truncated one.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

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
        layout_width: crate::cast::u16_sat(layout.layout_width),
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
    /// The widest display line laid out so far, measured before any clipping.
    ///
    /// Every path but the diagram one wraps to the target width, so the lines
    /// `push` receives are already the laid-out lines and this is simply the
    /// widest of them. The diagram path truncates instead, so it records the
    /// width of the artwork line it is about to cut down — otherwise the one
    /// truncation in the engine would be the one thing this could not see, and
    /// a caller comparing it against `width` would be told the document fits
    /// while columns were missing.
    layout_width: usize,
}

impl<'a> Layout<'a> {
    fn new(width: u16, palette: &'a Palette, source_line_count: usize) -> Layout<'a> {
        Layout {
            width,
            palette,
            max_source: crate::cast::u32_sat(source_line_count.saturating_sub(1)),
            styles: StyleTable::new(),
            lines: Vec::new(),
            layout_width: 0,
        }
    }

    /// Record that a line this wide was laid out.
    fn note_width(&mut self, width: usize) {
        self.layout_width = self.layout_width.max(width);
    }

    /// Wrap `line` to the target width and append the result.
    ///
    /// A line that already fits is emitted unchanged; one that does not is
    /// split, so no caller has to be trusted to respect the width itself.
    fn push(&mut self, source: Option<u32>, line: &Line) {
        let source = source.map(|s| s.min(self.max_source));
        for wrapped in wrap_spans(&line.spans, self.width) {
            let line = wrapped.to_line();
            self.note_width(line.width());
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
    ///
    /// Artwork wider than the window is clipped rather than wrapped. A soft
    /// wrap turns one row of a diagram into two half-rows, and half of a
    /// sequence diagram is neither a diagram nor its source — it is noise.
    /// Dropping the right edge instead is what a terminal pane too narrow for
    /// the drawing does anyway, and it keeps every row on its own line, so the
    /// shape of the diagram survives even when its right-hand side does not.
    /// Wrapping stays right for the fallback below, which is prose-shaped.
    fn push_mermaid(&mut self, source: &str, source_line: u32) {
        let source_line = source_line.min(self.max_source);
        let art_style = Style::default().fg(self.palette.foreground);

        // `max_width` is a hint the layout backend uses to pick an orientation,
        // not a clamp: a diagram can still come back wider than the budget.
        match render_text(source, Some(self.width as usize), MermaidTextBackend::Auto) {
            Ok(art) => {
                for line in art.lines() {
                    // Measured before the clip, so a caller can tell that this
                    // line was cut down. `push` then measures the clipped line
                    // too, which can only be narrower.
                    self.note_width(line.width());
                    let line = clip_to_width(line, self.width as usize);
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

/// `line` truncated to at most `max` display columns.
///
/// Measured in columns rather than bytes or characters, so a double-width CJK
/// glyph is never cut down the middle and left as half a character. Diagram
/// borders are single-width, but a node label is arbitrary text.
fn clip_to_width(line: &str, max: usize) -> &str {
    let mut used = 0usize;
    for (idx, ch) in line.char_indices() {
        let width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + width > max {
            return &line[..idx];
        }
        used += width;
    }
    line
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

    /// The document's text, one string per display line, joined by newlines.
    ///
    /// Joining rather than concatenating keeps line structure visible, which is
    /// what the tests below care about — a doubled blank line only shows up as
    /// `\n\n` if the boundaries survive into the string.
    fn lines_text(doc: &WireDoc) -> String {
        doc.lines
            .iter()
            .map(line_text)
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// One display line's text, without its trailing style information.
    fn line_text(line: &WireLine) -> String {
        line.spans.iter().map(|s| s.1.as_str()).collect()
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

    /// A sequence diagram for the clipping tests below.
    ///
    /// A sequence diagram is the case that motivated clipping, and it is also
    /// the case that now usually avoids it: the renderer wraps its labels and
    /// scans the wrap targets for the shortest layout that fits, so a budget it
    /// can meet leaves nothing to truncate. These tests use `TRUNCATING_WIDTH`,
    /// below the narrowest layout it can be compacted to.
    const WIDE_SEQUENCE: &str = "```mermaid\nsequenceDiagram\n    participant A as Client\n    participant B as Server\n    A->>B: a long enough request label\n    B-->>A: a long enough response\n```\n";

    /// A budget below the narrowest layout `WIDE_SEQUENCE` can be compacted to
    /// (35 columns, re-measured after the compaction change and unchanged —
    /// neither label has an unbreakable token, so there is no gap for the
    /// second wrapping pass to fill), which is what it takes to leave a diagram
    /// with something truncated: at any budget the diagram can meet, the engine
    /// re-lays it out to fit and there is no excess for `layout_width` to
    /// report.
    const TRUNCATING_WIDTH: u16 = 30;

    #[test]
    fn an_over_wide_diagram_is_drawn_and_clipped_rather_than_dumped_as_source() {
        let width = TRUNCATING_WIDTH;
        let doc = layout(WIDE_SEQUENCE, width);

        let text = lines_text(&doc);
        assert!(
            !text.contains("sequenceDiagram") && !text.contains("participant A"),
            "an over-wide diagram must still be drawn, not dumped as source:\n{text}"
        );
        assert!(
            text.contains('─') || text.contains('│'),
            "clipped artwork must keep its rules and borders:\n{text}"
        );

        for line in &doc.lines {
            assert!(
                display_width(line) <= width as usize,
                "clipped artwork must still fit {width} columns, got {}: {line:?}",
                display_width(line)
            );
        }
    }

    #[test]
    fn layout_width_is_the_widest_line_when_nothing_is_truncated() {
        let doc = layout("# Hi\n\nplain **bold** text\n", 40);

        assert_eq!(doc.layout_width, 15, "`plain bold text` is the widest line");
        assert!(doc.layout_width <= doc.width);
        assert_eq!(
            doc.layout_width as usize,
            doc.lines.iter().map(display_width).max().unwrap_or(0),
            "with nothing truncated, the reported width is the widest line emitted"
        );
    }

    #[test]
    fn layout_width_is_taken_before_truncation() {
        let width = TRUNCATING_WIDTH;
        let doc = layout(WIDE_SEQUENCE, width);

        assert!(
            doc.layout_width > width,
            "the sequence diagram is wider than {width}, so the reported layout \
             width must say so, got {}",
            doc.layout_width
        );
        for line in &doc.lines {
            assert!(
                display_width(line) <= width as usize,
                "the emitted lines still fit {width}, so the excess exists only \
                 in the reported width"
            );
        }
    }

    #[test]
    fn wrapping_never_reports_a_width_above_the_budget() {
        // Prose wraps rather than truncating, so a paragraph far wider than the
        // budget must not push `layout_width` above it — otherwise a reader
        // would read a wrapped document as a truncated one.
        let doc = layout(&"word ".repeat(200), 40);

        assert!(
            doc.layout_width <= doc.width,
            "wrapped prose reports {} against a budget of {}",
            doc.layout_width,
            doc.width
        );
    }

    #[test]
    fn clipping_keeps_one_display_line_per_artwork_row() {
        let width = TRUNCATING_WIDTH;
        let source = WIDE_SEQUENCE
            .trim_start_matches("```mermaid\n")
            .trim_end_matches("```\n");
        let art = crate::mermaid::render_text(
            source,
            Some(width as usize),
            crate::mermaid::MermaidTextBackend::Auto,
        )
        .expect("the fixture diagram must render");
        let rows = art.lines().count();
        assert!(rows > 1, "the fixture must be more than one row tall");

        let doc = layout(WIDE_SEQUENCE, width);
        // Every artwork row anchors to the fence at source line 0. One display
        // line per row is the whole point: a soft wrap would have split a
        // 100-column row into three and left the diagram unrecognisable.
        let drawn = doc
            .lines
            .iter()
            .filter(|l| l.source == Some(0) && !l.spans.is_empty())
            .count();
        assert_eq!(
            drawn, rows,
            "artwork must be clipped, not re-wrapped: {rows} rows became {drawn} display lines"
        );
    }

    #[test]
    fn clipping_never_splits_a_double_width_character() {
        // Each CJK glyph occupies two columns, so clipping to an odd width has
        // to stop before the glyph that would straddle the edge rather than cut
        // it into half a character.
        assert_eq!(clip_to_width("日本語", 5), "日本");
        assert_eq!(clip_to_width("日本語", 6), "日本語");
        assert_eq!(clip_to_width("日本語", 1), "");
        assert_eq!(clip_to_width("日本語", 0), "");

        // Anything that already fits is returned untouched.
        assert_eq!(clip_to_width("abc", 10), "abc");
        assert_eq!(clip_to_width("abc", 3), "abc");
        assert_eq!(clip_to_width("", 3), "");
    }

    #[test]
    fn a_crlf_document_renders_the_same_as_its_lf_twin() {
        let lf = "# Title\n\n```rust\nfn main() {}\nlet x = 1;\n```\n\nlast line\n";
        let crlf = lf.replace('\n', "\r\n");

        let a = serde_json::to_string(&layout(lf, 80)).expect("serialise");
        let b = serde_json::to_string(&layout(&crlf, 80)).expect("serialise");
        assert_eq!(
            a, b,
            "CRLF and LF sources must render identically; the endings are not content"
        );

        // The concrete symptom the normalisation removes: pulldown-cmark splits
        // a CRLF ending into two text events, and the code-block collector used
        // to read the stray `\r` as an extra line, putting a blank row between
        // every pair of code lines.
        let doc = layout(&crlf, 80);
        let lines: Vec<String> = doc.lines.iter().map(line_text).collect();
        let Some(first) = lines.iter().position(|l| l.contains("fn main() {}")) else {
            panic!("the first code line must be rendered:\n{}", lines.join("\n"));
        };
        let Some(second) = lines.iter().position(|l| l.contains("let x = 1;")) else {
            panic!("the second code line must be rendered:\n{}", lines.join("\n"));
        };
        assert_eq!(
            second,
            first + 1,
            "a CRLF code block must not gain blank rows between its lines:\n{}",
            lines.join("\n")
        );
    }

    #[test]
    fn a_crlf_document_keeps_the_same_line_count_as_its_lf_twin() {
        // The plugin indexes `source_map` with the editor's line count, so the
        // normalisation has to be line-count preserving — which collapsing
        // `\r\n` to `\n` is, and is the reason it is done here rather than by
        // rewriting the source on the plugin's side.
        let lf = "# Title\n\n```rust\nlet x = 1;\n```\n";
        let crlf = lf.replace('\n', "\r\n");
        assert_eq!(source_line_count(&crlf), source_line_count(lf));
        assert_eq!(
            layout(&crlf, 80).source_map.len(),
            source_line_count(lf),
            "the wire source map must still cover every source line"
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
            // The same fence written by an editor on Windows.
            "```rust\r\nfn main() { println!(\"hello\"); }\r\n```\r\n",
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
