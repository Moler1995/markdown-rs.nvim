//! The wire format: what the engine writes to stdout for the plugin to read.
//!
//! The contract is documented in `docs/md-render-format.md`; this module is
//! the normative definition of it.
//!
//! The shape is chosen for the reader, which is Lua. Three decisions follow
//! from that:
//!
//! * **A deduplicated style table.** The plugin defines one highlight group per
//!   distinct style and caches the mapping across renders, so a document with
//!   ten thousand bold spans should not repeat the colour triple ten thousand
//!   times. Spans reference a style by index into `styles`.
//! * **Spans as two-element arrays.** `[style_index, text]` rather than
//!   `{"s": 0, "t": "…"}`. Spans are the bulk of the payload and the shape is
//!   fixed, so field names would be pure overhead on both sides.
//! * **Both directions of the source map.** Each line names the source line it
//!   came from, and `source_map` names, for each source line, the first display
//!   line at or after it. Deriving the second from the first in Lua would mean
//!   reimplementing a scan that the engine has already done, and would let the
//!   two directions disagree.

use std::collections::HashMap;

use serde::Serialize;

use crate::style::{Color, Line, Modifier, Style};

/// The wire format's version. Bumped when a change to the shape would break a
/// reader that was written against the previous one.
pub const WIRE_VERSION: u32 = 1;

/// A colour as the plugin receives it.
///
/// RGB colours become `#rrggbb`. The sixteen named colours become their
/// lowercase names (`"red"`, `"lightblue"`, …) and indexed colours become
/// `"indexed:N"`, so a reader can always recover the original [`Color`]
/// exactly rather than being forced through an RGB approximation.
///
/// `None` is the terminal's default colour and serialises as `null`.
#[must_use]
pub fn color_to_wire(color: Color) -> Option<String> {
    let name = match color {
        Color::Reset => return None,
        Color::Black => "black".to_string(),
        Color::Red => "red".to_string(),
        Color::Green => "green".to_string(),
        Color::Yellow => "yellow".to_string(),
        Color::Blue => "blue".to_string(),
        Color::Magenta => "magenta".to_string(),
        Color::Cyan => "cyan".to_string(),
        Color::Gray => "gray".to_string(),
        Color::DarkGray => "darkgray".to_string(),
        Color::LightRed => "lightred".to_string(),
        Color::LightGreen => "lightgreen".to_string(),
        Color::LightYellow => "lightyellow".to_string(),
        Color::LightBlue => "lightblue".to_string(),
        Color::LightMagenta => "lightmagenta".to_string(),
        Color::LightCyan => "lightcyan".to_string(),
        Color::White => "white".to_string(),
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
        Color::Indexed(i) => format!("indexed:{i}"),
    };
    Some(name)
}

/// One entry of the `styles` table.
///
/// `fg` and `bg` are always present — `null` carries the meaning "terminal
/// default" — while modifier flags are omitted when false, which is the common
/// case for most of them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WireStyle {
    pub fg: Option<String>,
    pub bg: Option<String>,
    #[serde(skip_serializing_if = "is_false")]
    pub bold: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub dim: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub italic: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub underline: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub strikethrough: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub reverse: bool,
}

#[allow(clippy::trivially_copy_pass_by_ref)] // serde requires `&bool` here.
fn is_false(value: &bool) -> bool {
    !*value
}

impl From<Style> for WireStyle {
    fn from(style: Style) -> WireStyle {
        WireStyle {
            fg: style.fg.and_then(color_to_wire),
            bg: style.bg.and_then(color_to_wire),
            bold: style.has_modifier(Modifier::BOLD),
            dim: style.has_modifier(Modifier::DIM),
            italic: style.has_modifier(Modifier::ITALIC),
            underline: style.has_modifier(Modifier::UNDERLINED),
            strikethrough: style.has_modifier(Modifier::CROSSED_OUT),
            reverse: style.has_modifier(Modifier::REVERSED),
        }
    }
}

/// A span as the plugin receives it: `[style_index, text]`.
///
/// A two-field tuple struct so serde emits an array rather than an object.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WireSpan(pub u32, pub String);

/// One display line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WireLine {
    /// The 0-indexed source line this display line came from, or `null` for a
    /// line with no source counterpart — a table border, a diagram's artwork,
    /// a blank spacer the layout inserted.
    pub source: Option<u32>,
    pub spans: Vec<WireSpan>,
}

/// The document as the plugin receives it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WireDoc {
    pub version: u32,
    /// The width the engine laid out to, echoed back so the plugin can discard
    /// a result that arrived after the window changed size.
    pub width: u16,
    /// The widest display line the engine laid the document out at, measured in
    /// display columns *before* any truncation.
    ///
    /// Diagram artwork that does not fit is truncated rather than wrapped, and
    /// the dropped columns are not in `lines`, so a reader cannot tell a
    /// diagram that fits from one that was cut down by looking at the output.
    /// This is what it can tell them by: the document was truncated exactly
    /// when `layout_width > width`.
    ///
    /// It covers the whole document rather than diagrams alone, so a caller
    /// does not have to know which block was truncated to find out that one was.
    pub layout_width: u16,
    pub styles: Vec<WireStyle>,
    pub lines: Vec<WireLine>,
    /// One entry per source line: the index of the first display line at or
    /// after that source line. Length equals the document's source line count.
    pub source_map: Vec<u32>,
}

/// Interns styles as they are emitted, so `styles` holds each distinct style
/// exactly once and spans reference it by index.
///
/// Insertion order is preserved, which is what makes the output deterministic:
/// two renders of the same input intern their styles in the same sequence and
/// therefore produce byte-identical JSON.
#[derive(Debug, Default)]
pub struct StyleTable {
    index: HashMap<Style, u32>,
    styles: Vec<WireStyle>,
}

impl StyleTable {
    #[must_use]
    pub fn new() -> StyleTable {
        StyleTable::default()
    }

    /// Return the index of `style`, adding it if this is the first sighting.
    pub fn intern(&mut self, style: Style) -> u32 {
        if let Some(&existing) = self.index.get(&style) {
            return existing;
        }
        let idx = crate::cast::u32_sat(self.styles.len());
        self.styles.push(WireStyle::from(style));
        self.index.insert(style, idx);
        idx
    }

    /// Convert a laid-out line into its wire form, interning each span's style.
    ///
    /// Adjacent spans carrying the same style are merged into one, so a line of
    /// uniform styling leaves with a single span rather than one per
    /// pulldown-cmark event that contributed to it.
    pub fn line(&mut self, source: Option<u32>, line: &Line) -> WireLine {
        let mut spans: Vec<WireSpan> = Vec::with_capacity(line.spans.len());
        for span in &line.spans {
            let style_idx = self.intern(span.style);
            if let Some(last) = spans.last_mut()
                && last.0 == style_idx
            {
                last.1.push_str(&span.content);
                continue;
            }
            spans.push(WireSpan(style_idx, span.content.clone()));
        }
        WireLine { source, spans }
    }

    /// Finish the table, returning the deduplicated styles.
    #[must_use]
    pub fn into_styles(self) -> Vec<WireStyle> {
        self.styles
    }
}

/// Build `source_map` from the emitted lines and the document's source line
/// count.
///
/// `source_map[i]` is the index of the first display line whose source line is
/// at or after `i`, ignoring synthetic lines. When no display line is at or
/// after `i` — the tail of a document whose last construct was a collapsed
/// diagram, say — the entry is clamped to the last display line, so every
/// value is a valid index into `lines`.
///
/// An empty `lines` yields an empty map: there is no index to point at.
#[must_use]
pub fn build_source_map(lines: &[WireLine], source_line_count: usize) -> Vec<u32> {
    if lines.is_empty() {
        return Vec::new();
    }
    let mut map = Vec::with_capacity(source_line_count);
    // Walk the display lines once. `cursor` only ever moves forward, so the
    // whole scan is linear rather than one search per source line.
    let mut cursor = 0usize;
    for source_line in 0..source_line_count {
        let target = crate::cast::u32_sat(source_line);
        while cursor < lines.len() {
            match lines[cursor].source {
                Some(line_source) if line_source >= target => break,
                _ => cursor += 1,
            }
        }
        // Clamp rather than point past the end: the plugin indexes `lines` with
        // this value directly.
        map.push(crate::cast::u32_sat(cursor.min(lines.len() - 1)));
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::style::Span;

    #[test]
    fn rgb_colours_serialise_as_hex() {
        assert_eq!(
            color_to_wire(Color::Rgb(0xcb, 0xa6, 0xf7)).as_deref(),
            Some("#cba6f7")
        );
        assert_eq!(color_to_wire(Color::Rgb(0, 0, 0)).as_deref(), Some("#000000"));
        assert_eq!(
            color_to_wire(Color::Rgb(255, 255, 255)).as_deref(),
            Some("#ffffff")
        );
    }

    #[test]
    fn indexed_and_named_colours_round_trip_their_identity() {
        assert_eq!(color_to_wire(Color::Indexed(5)).as_deref(), Some("indexed:5"));
        assert_eq!(color_to_wire(Color::Indexed(0)).as_deref(), Some("indexed:0"));
        assert_eq!(color_to_wire(Color::Red).as_deref(), Some("red"));
        assert_eq!(color_to_wire(Color::LightBlue).as_deref(), Some("lightblue"));
        // Two different colours must not collide on one wire string.
        assert_ne!(color_to_wire(Color::Indexed(1)), color_to_wire(Color::Red));
    }

    #[test]
    fn default_colour_serialises_as_null() {
        assert_eq!(color_to_wire(Color::Reset), None);

        let style = Style::default();
        let wire = WireStyle::from(style);
        assert_eq!(wire.fg, None);
        assert_eq!(wire.bg, None);
        assert!(!wire.bold && !wire.italic && !wire.underline);
    }

    #[test]
    fn modifier_combinations_map_to_the_right_flags() {
        let style = Style::default()
            .fg(Color::Rgb(1, 2, 3))
            .bg(Color::Rgb(4, 5, 6))
            .add_modifier(Modifier::BOLD)
            .add_modifier(Modifier::ITALIC);
        let wire = WireStyle::from(style);
        assert!(wire.bold && wire.italic);
        assert!(!wire.underline && !wire.strikethrough && !wire.dim && !wire.reverse);
        assert_eq!(wire.fg.as_deref(), Some("#010203"));
        assert_eq!(wire.bg.as_deref(), Some("#040506"));

        let other = Style::default()
            .add_modifier(Modifier::UNDERLINED)
            .add_modifier(Modifier::CROSSED_OUT)
            .add_modifier(Modifier::REVERSED)
            .add_modifier(Modifier::DIM);
        let wire = WireStyle::from(other);
        assert!(wire.underline && wire.strikethrough && wire.reverse && wire.dim);
        assert!(!wire.bold && !wire.italic);
    }

    #[test]
    fn false_modifiers_are_omitted_from_the_json() {
        let json = serde_json::to_string(&WireStyle::from(
            Style::default().fg(Color::Rgb(1, 2, 3)).add_modifier(Modifier::BOLD),
        ))
        .expect("serialise");
        assert_eq!(json, r##"{"fg":"#010203","bg":null,"bold":true}"##);
    }

    #[test]
    fn the_same_style_on_many_lines_yields_one_table_entry() {
        let mut table = StyleTable::new();
        let style = Style::default()
            .fg(Color::Rgb(1, 2, 3))
            .add_modifier(Modifier::BOLD);

        let mut indices = Vec::new();
        for _ in 0..50 {
            indices.push(table.line(Some(0), &Line::from(Span::styled("x", style))));
        }

        let styles = table.into_styles();
        assert_eq!(styles.len(), 1, "fifty identical spans must intern to one style");
        for line in &indices {
            assert_eq!(line.spans[0].0, 0);
        }
    }

    #[test]
    fn distinct_styles_each_get_their_own_entry() {
        let mut table = StyleTable::new();
        let a = Style::default().fg(Color::Rgb(1, 1, 1));
        let b = Style::default().fg(Color::Rgb(2, 2, 2));

        let first = table.line(Some(0), &Line::from(Span::styled("a", a)));
        let second = table.line(Some(1), &Line::from(Span::styled("b", b)));
        let third = table.line(Some(2), &Line::from(Span::styled("a again", a)));

        assert_eq!(first.spans[0].0, 0);
        assert_eq!(second.spans[0].0, 1);
        assert_eq!(third.spans[0].0, 0, "a repeated style must reuse its index");
        assert_eq!(table.into_styles().len(), 2);
    }

    #[test]
    fn adjacent_same_style_spans_merge_into_one() {
        let mut table = StyleTable::new();
        let style = Style::default().fg(Color::Rgb(9, 9, 9));
        let line = Line::from(vec![
            Span::styled("Hel", style),
            Span::styled("lo, ", style),
            Span::styled("world", style),
        ]);

        let wire = table.line(Some(0), &line);
        assert_eq!(wire.spans.len(), 1, "a uniform line must emit a single span");
        assert_eq!(wire.spans[0].1, "Hello, world");
    }

    #[test]
    fn spans_of_different_style_stay_separate_and_keep_their_order() {
        let mut table = StyleTable::new();
        let a = Style::default().fg(Color::Rgb(1, 1, 1));
        let b = Style::default().fg(Color::Rgb(2, 2, 2));
        let line = Line::from(vec![
            Span::styled("bold ", a),
            Span::styled("plain", b),
            Span::styled(" bold", a),
        ]);

        let wire = table.line(Some(7), &line);
        assert_eq!(wire.source, Some(7));
        assert_eq!(wire.spans.len(), 3);
        assert_eq!(wire.spans[0].1, "bold ");
        assert_eq!(wire.spans[1].1, "plain");
        assert_eq!(wire.spans[2].1, " bold");
        assert_ne!(wire.spans[0].0, wire.spans[1].0);
        assert_eq!(wire.spans[0].0, wire.spans[2].0);
    }

    #[test]
    fn empty_lines_serialise_with_no_spans() {
        let mut table = StyleTable::new();
        let wire = table.line(Some(3), &Line::from(""));
        assert!(wire.spans.is_empty());
        assert_eq!(wire.source, Some(3));
    }

    #[test]
    fn source_map_points_at_the_first_line_at_or_after_each_source_line() {
        let lines = vec![
            WireLine { source: Some(0), spans: Vec::new() },
            WireLine { source: Some(0), spans: Vec::new() },
            WireLine { source: None, spans: Vec::new() }, // synthetic
            WireLine { source: Some(2), spans: Vec::new() },
            WireLine { source: Some(5), spans: Vec::new() },
        ];

        // Source lines 0..=6; source lines 1, 3 and 4 have no display line of
        // their own, so they resolve forward to the next one that does. The
        // last source line has nothing at or after it, so it clamps to the
        // final display line rather than pointing past the end.
        let map = build_source_map(&lines, 7);
        assert_eq!(map, vec![0, 3, 3, 4, 4, 4, 4]);
    }

    #[test]
    fn source_map_tail_clamps_to_the_last_line() {
        let lines = vec![WireLine { source: Some(0), spans: Vec::new() }];
        let map = build_source_map(&lines, 3);
        // Every entry is a valid index into `lines`, which has length 1.
        assert_eq!(map, vec![0, 0, 0]);
    }

    #[test]
    fn every_source_map_entry_is_a_valid_line_index() {
        let lines = vec![
            WireLine { source: Some(0), spans: Vec::new() },
            WireLine { source: None, spans: Vec::new() },
            WireLine { source: Some(4), spans: Vec::new() },
        ];
        let map = build_source_map(&lines, 9);
        assert_eq!(map.len(), 9);
        for (i, &entry) in map.iter().enumerate() {
            assert!(
                (entry as usize) < lines.len(),
                "source line {i} maps to display line {entry}, but there are only {}",
                lines.len()
            );
        }
    }

    #[test]
    fn source_map_of_an_empty_document_is_empty() {
        assert!(build_source_map(&[], 0).is_empty());
    }
}
