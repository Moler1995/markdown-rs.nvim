//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
//!
//! The document model: what a rendered markdown document is made of.
//!
//! A document is a sequence of [`DocBlock`] values rather than one flat run of
//! lines, because a diagram and a table each need to be laid out as a unit —
//! a table's column widths depend on every cell in the column, and a diagram
//! has to be fitted to the width as a whole.
//!
//! # What the origin had and this does not
//!
//! The origin's blocks carried stable content-derived ids, byte ranges into the
//! source, cached heights, hyperlink positions and heading anchors. All of that
//! served the TUI: the ids keyed wrap caches, the byte ranges drove cursor
//! hit-testing and block re-parsing on edit, the heights fed scroll arithmetic,
//! and the links fed a link picker. An engine that renders once and hands back
//! a line list needs none of it — the line list *is* the layout. What remains
//! is the content and the source anchoring.

use pulldown_cmark::Options;

use crate::style::{Span, Text};

/// The pulldown-cmark option set the renderer parses with.
///
/// Tables, strikethrough, task lists, inline and display math, and YAML/TOML
/// frontmatter are all enabled. The metadata-block options make a leading
/// `---`/`+++` delimited block parse as document metadata rather than as a
/// thematic break followed by markdown; only a block at the very start of the
/// document qualifies, so a mid-document `---` still renders as a horizontal
/// rule.
#[must_use]
pub fn markdown_options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_MATH
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
        | Options::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS
}

/// One table cell's content as a sequence of styled spans.
pub type CellSpans = Vec<Span>;

/// Structured representation of a markdown table, parsed once at render time.
///
/// Each cell is a `Vec<Span>` preserving inline styling (bold, italic, code,
/// links, strikethrough). `natural_widths` is measured from the sum of
/// `unicode_width` across each cell's spans and is used by the table layout to
/// decide column widths.
#[derive(Debug, Clone)]
pub struct TableBlock {
    pub headers: Vec<CellSpans>,
    pub rows: Vec<Vec<CellSpans>>,
    pub alignments: Vec<pulldown_cmark::Alignment>,
    /// Maximum display width of any cell per column, including the header.
    pub natural_widths: Vec<usize>,
    /// 0-indexed source line where the opening `|` row of the table appears.
    pub source_line: u32,
    /// Source lines for each logical row: index 0 is the header, indices
    /// `1..=rows.len()` are body rows. Length equals `1 + rows.len()`.
    pub row_source_lines: Vec<u32>,
}

/// A single rendered block in a document.
#[derive(Debug)]
pub enum DocBlock {
    /// A run of styled lines, with the source line each one came from.
    Text {
        text: Text,
        /// Parallel to `text.lines`: the 0-indexed source line for each
        /// rendered line. `source_lines.len() == text.lines.len()` is a
        /// maintained invariant.
        source_lines: Vec<u32>,
    },
    /// A mermaid diagram, kept as its raw source for the caller to lay out.
    ///
    /// The engine does not draw the diagram itself: fitting text art to a
    /// width is a layout decision, and the caller knows the width. See
    /// [`crate::mermaid`].
    Mermaid {
        /// The diagram source, without the fence.
        source: String,
        /// 0-indexed source line where the opening fence appears.
        source_line: u32,
    },
    /// A parsed markdown table rendered with fair-share column widths.
    Table(TableBlock),
}

impl DocBlock {
    /// The 0-indexed source line this block is anchored at, if it has one.
    ///
    /// `Text` blocks report their first rendered line's source; the other
    /// variants report the line their opening construct sits on (the
    /// ` ```mermaid ` fence, the table's header row). `None` means the block
    /// has no rendered lines at all.
    #[must_use]
    pub fn anchor_source_line(&self) -> Option<u32> {
        match self {
            DocBlock::Text { source_lines, .. } => source_lines.first().copied(),
            DocBlock::Mermaid { source_line, .. } => Some(*source_line),
            DocBlock::Table(t) => Some(t.source_line),
        }
    }
}
