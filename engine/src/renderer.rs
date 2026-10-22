//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
//!
//! The markdown renderer: pulldown-cmark events to styled display lines.
//!
//! # What was removed from the origin
//!
//! The origin's renderer also recorded hyperlink positions, heading anchors,
//! stable content hashes, and contiguous byte ranges over the source, and could
//! emit block math as an image placeholder instead of text. Every one of those
//! served the TUI's own interaction model — a link picker, a table-of-contents,
//! wrap caches, and cursor-byte-offset lookup for live editing. None of them
//! survive into the engine; what is left is the part that decides what a reader
//! sees and which source line each display line came from.
//!
//! Block math is always rendered as a bordered Unicode approximation. The
//! origin's image mode existed so the TUI could hand the formula to a graphics
//! protocol; there is no graphics protocol here.

use std::borrow::Cow;
use std::ops::Range;

use pulldown_cmark::{CodeBlockKind, Event, MetadataBlockKind, Options, Parser, Tag, TagEnd};
use unicode_width::UnicodeWidthStr;

use crate::block::{CellSpans, DocBlock, TableBlock, markdown_options};
use crate::style::{Line, Modifier, Span, Style, Text};
use crate::theme::{Palette, Theme, Tokens};

/// Label drawn into the top border of a rendered frontmatter block, so a reader
/// can tell document metadata from an ordinary fenced YAML/TOML block at a
/// glance. Includes its surrounding spaces — see `render_code_block`.
const FRONTMATTER_LABEL: &str = " frontmatter ";

/// Render a markdown string into a sequence of [`DocBlock`] values.
///
/// Mermaid fenced code blocks produce [`DocBlock::Mermaid`] entries; tables
/// produce [`DocBlock::Table`]; all other content is grouped into
/// [`DocBlock::Text`] runs. Consecutive text lines are merged so there is at
/// most one `Text` block between two other blocks.
///
/// Each rendered line carries a 0-indexed source line derived from
/// pulldown-cmark's byte-offset spans, which is what lets a caller map a
/// display position back to the document.
///
/// # Arguments
///
/// * `content` – raw markdown source.
/// * `palette` – colour palette for the active theme.
/// * `theme` – the active theme; used to select the matching syntect
///   highlighting theme for fenced code blocks.
#[must_use]
pub fn render_markdown(content: &str, palette: &Palette, theme: Theme) -> Vec<DocBlock> {
    render_with_options(content, palette, theme, markdown_options())
}

/// [`render_markdown`] with an explicit pulldown-cmark option set.
fn render_with_options(
    content: &str,
    palette: &Palette,
    theme: Theme,
    opts: Options,
) -> Vec<DocBlock> {
    // Normalise line endings first, so the parser and the byte-offset table
    // below are built from the same string.
    let content = normalise_newlines(content);
    let parser = Parser::new_ext(&content, opts);
    // Derive tokens from the theme once; the renderer stores them so that
    // `render_code_block` can read from semantic slots (e.g.
    // `tokens.surface.raised`) rather than opaque palette field names.
    let tokens = Tokens::from_theme(theme);
    let renderer = MdRenderer::new(palette, tokens, theme);
    renderer.render(&content, parser)
}

/// `content` with CRLF line endings collapsed to LF.
///
/// pulldown-cmark emits the `\r` and the `\n` of a CRLF ending as two separate
/// `Text` events. Outside a code block that makes no difference — the two are
/// concatenated back into one span. Inside one it does: `handle_text` splits
/// every event on `\n`, so the stray `\r` becomes a line of its own and every
/// CRLF line of a fenced block is followed by a blank one.
///
/// Collapsing here, before anything reads the text, is what keeps the fix
/// honest: `\r\n` -> `\n` preserves the line count, so the byte offsets
/// `build_line_boundaries` derives still name the same source lines the editor
/// reports.
///
/// A lone `\r` is left alone. No editor this engine reads from writes one, and
/// rewriting it would be a guess about what it meant.
fn normalise_newlines(content: &str) -> Cow<'_, str> {
    if content.contains("\r\n") {
        Cow::Owned(content.replace("\r\n", "\n"))
    } else {
        Cow::Borrowed(content)
    }
}

/// Pre-compute line-start byte offsets for `content`.
///
/// `line_boundaries[i]` is the byte offset where line `i` starts (0-indexed).
/// There is always at least one entry: `line_boundaries[0] == 0`.
fn build_line_boundaries(content: &str) -> Vec<usize> {
    let mut boundaries = vec![0];
    for (i, b) in content.as_bytes().iter().enumerate() {
        if *b == b'\n' {
            boundaries.push(i + 1);
        }
    }
    boundaries
}

/// Given a byte offset into the source, return the 0-indexed source line.
///
/// Uses a binary search into the pre-computed `boundaries` slice.
fn byte_offset_to_line(offset: usize, boundaries: &[usize]) -> u32 {
    match boundaries.binary_search(&offset) {
        // Exact match: the offset is itself the start of a line.
        Ok(i) => crate::cast::u32_sat(i),
        // No exact match: `i` is the insertion point — the line that started
        // before `offset` is at index `i - 1`.
        Err(i) => crate::cast::u32_sat(i.saturating_sub(1)),
    }
}

// ── Internal renderer ────────────────────────────────────────────────────────

#[allow(clippy::struct_excessive_bools)]
struct MdRenderer {
    /// Accumulates lines for the current `Text` block.
    lines: Vec<Line>,
    /// Completed blocks emitted so far.
    blocks: Vec<DocBlock>,
    current_spans: Vec<Span>,
    style_stack: Vec<Style>,
    list_depth: usize,
    list_counters: Vec<Option<u64>>,
    in_code_block: bool,
    /// `Some(lang)` when inside a fenced block — `None` for indented blocks.
    code_block_lang: Option<String>,
    code_block_content: Vec<String>,
    in_heading: bool,
    in_blockquote: bool,
    /// True while inside a link's text. A soft break inside a link is rendered
    /// as a space rather than a line break, so link text stays on one line.
    in_link: bool,
    in_table: bool,
    table_alignments: Vec<pulldown_cmark::Alignment>,
    table_row: Vec<CellSpans>,
    table_rows: Vec<Vec<CellSpans>>,
    table_header_row: Option<Vec<CellSpans>>,
    table_header: bool,
    /// Syntect theme name corresponding to the active theme. Used to resolve
    /// the correct token colours when highlighting fenced code blocks.
    syntax_theme_name: &'static str,
    /// Semantic design tokens for the active theme. All per-element colours are
    /// read directly from these slots rather than cached per-field copies, so
    /// the sourcing decisions (e.g. `surface.raised` for code-block
    /// backgrounds) are visible at every call site.
    tokens: Tokens,

    // ── Source-line tracking ─────────────────────────────────────────────────
    /// Start byte offset of each source line: `line_boundaries[i]` is the byte
    /// offset where line `i` begins. Built once from `content` at render start.
    line_boundaries: Vec<usize>,
    /// 0-indexed source line of the most-recently processed event. Updated
    /// before dispatching each `(event, span)` pair.
    current_source_line: u32,
    /// 0-indexed source line the spans currently sitting in `current_spans`
    /// were accumulated under.
    ///
    /// Usually the same as `current_source_line`, and deliberately separate for
    /// the one place they differ: `Tag::Item` flushes the parent item's line
    /// after the stamp has already advanced to the nested item that triggered
    /// it, so re-reading `current_source_line` there attributes the parent's
    /// bullet to its child. Recorded when a line's spans begin, not when it is
    /// flushed.
    span_source_line: u32,
    /// Parallel to `self.lines` — one entry per rendered line.
    /// Invariant: `current_source_lines.len() == lines.len()` after every
    /// `flush_line` / `push_blank_line` call.
    current_source_lines: Vec<u32>,
    /// 0-indexed source line where the current verbatim block begins.
    ///
    /// For a fenced block or a frontmatter block this is the line holding the
    /// opening delimiter, and the content starts on the next line. An indented
    /// code block has no delimiter, so its `span.start` *is* its first content
    /// line. `code_block_fenced` is what tells the two apart — the language is
    /// not a reliable signal, because an untagged fence has none either.
    code_block_start_line: u32,
    /// Whether the current verbatim block was opened by a delimiter.
    code_block_fenced: bool,
    /// 0-indexed source line where the current table's opening row sits.
    table_start_line: u32,
    /// Source line of the table row currently being accumulated.
    current_table_row_source_line: u32,
    /// Source lines for every logical row in the current table. Index 0 is the
    /// header row; indices `1..=table_rows.len()` are body rows. Flushed into
    /// `TableBlock::row_source_lines` in `emit_table_block`.
    table_row_source_lines: Vec<u32>,

    // ── Image references ─────────────────────────────────────────────────────
    /// True while collecting an image's alt text.
    in_image: bool,
    /// Whether the image being collected becomes a `DocBlock::Image` of its
    /// own rather than inline alt text.
    ///
    /// A table cell and a heading hold a span list, not a sequence of blocks:
    /// artwork in either would break the table's columns or the heading's
    /// line, so there the reference stays what it always was — its alt text.
    image_as_block: bool,
    /// Destination of the image being collected.
    image_dest: String,
    /// Alt text of the image being collected, in the inline style it was
    /// written with.
    image_alt: Vec<Span>,
    /// Source line where the image's `![` sits.
    image_source_line: u32,
    /// True when the last block emitted was an image. A paragraph that ends
    /// there has no pending spans to flush, and flushing the empty ones would
    /// add a second blank line under the artwork.
    after_image_block: bool,
}

impl MdRenderer {
    fn new(palette: &Palette, tokens: Tokens, theme: Theme) -> Self {
        Self {
            lines: Vec::new(),
            blocks: Vec::new(),
            current_spans: Vec::new(),
            style_stack: vec![Style::default().fg(palette.foreground)],
            list_depth: 0,
            list_counters: Vec::new(),
            in_code_block: false,
            code_block_lang: None,
            code_block_content: Vec::new(),
            in_heading: false,
            in_blockquote: false,
            in_link: false,
            in_table: false,
            table_alignments: Vec::new(),
            table_row: Vec::new(),
            table_rows: Vec::new(),
            table_header_row: None,
            table_header: false,
            syntax_theme_name: theme.syntax_theme_name(),
            tokens,
            line_boundaries: Vec::new(),
            current_source_line: 0,
            span_source_line: 0,
            current_source_lines: Vec::new(),
            code_block_start_line: 0,
            code_block_fenced: false,
            table_start_line: 0,
            current_table_row_source_line: 0,
            table_row_source_lines: Vec::new(),
            in_image: false,
            image_as_block: false,
            image_dest: String::new(),
            image_alt: Vec::new(),
            image_source_line: 0,
            after_image_block: false,
        }
    }

    fn current_style(&self) -> Style {
        self.style_stack.last().copied().unwrap_or_default()
    }

    fn push_style(&mut self, modifier: Style) {
        let base = self.current_style();
        self.style_stack.push(base.patch(modifier));
    }

    fn pop_style(&mut self) {
        if self.style_stack.len() > 1 {
            self.style_stack.pop();
        }
    }

    fn flush_line(&mut self) {
        if self.in_table {
            return;
        }
        let spans = std::mem::take(&mut self.current_spans);
        if self.in_blockquote && !self.in_code_block {
            let mut bq_spans = vec![Span::styled(
                "│ ".to_string(),
                Style::default().fg(self.tokens.list.block_quote_border),
            )];
            bq_spans.extend(spans);
            self.lines.push(Line::from(bq_spans));
        } else {
            self.lines.push(Line::from(spans));
        }
        // Maintain the parallel source_lines invariant.
        self.current_source_lines.push(self.current_source_line);
    }

    fn push_blank_line(&mut self) {
        if self.in_table {
            return;
        }
        self.lines.push(Line::from(""));
        // Blank lines inherit the source line of the surrounding context.
        self.current_source_lines.push(self.current_source_line);
    }

    /// Drain `self.lines` into a `DocBlock::Text` if there are any pending lines.
    ///
    /// Invariant: `source_lines.len() == text.lines.len()` is enforced by a
    /// debug assertion before pushing the block.
    fn flush_text_block(&mut self) {
        if self.lines.is_empty() {
            // Drop orphaned source_lines that accumulated without any matching
            // rendered line (can happen around pure-table sections).
            self.current_source_lines.clear();
        } else {
            let lines = std::mem::take(&mut self.lines);
            let source_lines = std::mem::take(&mut self.current_source_lines);
            // In debug builds, catch any mismatch between rendered lines and
            // their source-line annotations immediately.
            debug_assert_eq!(
                lines.len(),
                source_lines.len(),
                "source_lines length {} != lines length {}",
                source_lines.len(),
                lines.len(),
            );
            self.blocks.push(DocBlock::Text {
                text: Text::from(lines),
                source_lines,
            });
        }
    }

    /// Drive the render loop.
    ///
    /// `content` is the raw markdown string; it is used to build the
    /// `line_boundaries` table for byte-offset-to-line translation. `parser` is
    /// the pulldown-cmark parser constructed from the same string.
    #[allow(clippy::too_many_lines)]
    fn render(mut self, content: &str, parser: Parser) -> Vec<DocBlock> {
        // Build the line boundary table once. O(n) in the source length.
        self.line_boundaries = build_line_boundaries(content);

        // Use the offset iterator so every event carries a byte-range into the
        // original source, letting us map events back to source lines.
        for (event, span) in parser.into_offset_iter() {
            // Stamp the current source line from the event's start offset before
            // dispatching. All `lines.push` paths below inherit this.
            //
            // Skip End events: their span starts at the *opening* of the block
            // (e.g. `End(Paragraph)` for a multi-line paragraph spans 0..N, so
            // `span.start` resets us to the first source line). When
            // `TagEnd::Paragraph` then calls `flush_line` to emit the trailing
            // accumulated spans (the last source line of the paragraph), it
            // should record the line where that text *actually lives*, not where
            // the paragraph began. Leaving `current_source_line` at whatever the
            // last inline event (Text / SoftBreak / Code) set it to gives the
            // correct value.
            // Whether this event starts a fresh line. Read before dispatching,
            // because the line it may flush is the previous one.
            let starting_a_line = self.current_spans.is_empty();

            if !matches!(event, Event::End(_)) {
                self.current_source_line = byte_offset_to_line(span.start, &self.line_boundaries);
            }

            if starting_a_line {
                // Optimistic: set even for events that push no span, since the
                // next event to start a line overwrites it before it is read.
                self.span_source_line = self.current_source_line;
            }

            match event {
                Event::Start(tag) => self.start_tag(tag, &span),
                Event::End(tag) => self.end_tag(tag, &span),
                Event::Text(text) => self.handle_text(&text),
                Event::Code(code) => {
                    let style = self
                        .current_style()
                        .fg(self.tokens.syntax.inline_code)
                        .add_modifier(Modifier::BOLD);
                    let span = Span::styled(format!("`{code}`"), style);
                    if self.in_image && self.image_as_block {
                        self.image_alt.push(span);
                    } else {
                        self.current_spans.push(span);
                    }
                }
                Event::SoftBreak => {
                    // Preserve the source line break instead of joining the two
                    // sides with a space: a line's height would otherwise
                    // disagree with what the caller measures.
                    //
                    // Inside a link, a table cell or a list item we still emit a
                    // space. A link's text has to stay on one line; a table cell
                    // renders as a joined string, not through `flush_line`; and a
                    // list item's bullet/indent prefix is only emitted on
                    // `Tag::Item`, so splitting would leave the continuation at
                    // column 0 instead of aligned under the marker.
                    let in_list = self.list_depth > 0;
                    if self.in_link || self.in_table || in_list {
                        self.current_spans
                            .push(Span::styled(" ".to_string(), self.current_style()));
                    } else {
                        self.flush_line();
                    }
                }
                Event::HardBreak => {
                    self.flush_line();
                }
                Event::Rule => {
                    self.flush_line();
                    self.lines.push(Line::from(Span::styled(
                        "─".repeat(60),
                        Style::default().fg(self.tokens.text.muted),
                    )));
                    // Rule line and the blank after it both map to the current
                    // source line.
                    self.current_source_lines.push(self.current_source_line);
                    self.push_blank_line();
                }
                Event::TaskListMarker(checked) => {
                    let marker = if checked { "☑ " } else { "☐ " };
                    self.current_spans.push(Span::styled(
                        marker.to_string(),
                        Style::default().fg(self.tokens.list.task_marker),
                    ));
                }
                Event::InlineMath(math) => {
                    // Convert LaTeX to a Unicode approximation and render
                    // inline, styled like inline code but italic so readers can
                    // tell math from code at a glance.
                    let rendered = crate::math::latex_to_unicode(&math);
                    let style = self
                        .current_style()
                        .fg(self.tokens.syntax.inline_code)
                        .add_modifier(Modifier::ITALIC);
                    self.current_spans.push(Span::styled(rendered, style));
                }
                Event::DisplayMath(math) => {
                    // Convert LaTeX to Unicode and render as a bordered block
                    // labelled "math", mirroring the code-block frame.
                    let rendered = crate::math::latex_to_unicode(&math);
                    self.flush_line();
                    let border_style = Style::default().fg(self.tokens.syntax.code_border);
                    let math_style = Style::default()
                        .fg(self.tokens.syntax.code_fg)
                        .bg(self.tokens.surface.raised)
                        .add_modifier(Modifier::ITALIC);
                    let math_lines: Vec<&str> = rendered.lines().collect();
                    let max_width = math_lines
                        .iter()
                        .map(|l| UnicodeWidthStr::width(*l))
                        .max()
                        .unwrap_or(0)
                        .max(20);
                    let inner_width = max_width + 1;
                    let label = " math ";

                    self.push_blank_line();
                    // Top border with "math" label.
                    self.lines.push(Line::from(vec![
                        Span::styled("╭".to_string(), border_style),
                        Span::styled(
                            label.to_string(),
                            Style::default()
                                .fg(self.tokens.syntax.inline_code)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(
                            format!(
                                "{}╮",
                                "─".repeat(inner_width + 1 - label.len().min(inner_width))
                            ),
                            border_style,
                        ),
                    ]));
                    self.current_source_lines.push(self.current_source_line);
                    // Content lines.
                    for line in &math_lines {
                        self.lines.push(Line::from(vec![
                            Span::styled(
                                "│ ".to_string(),
                                Style::default()
                                    .fg(self.tokens.syntax.code_border)
                                    .bg(self.tokens.surface.raised),
                            ),
                            Span::styled(format!("{line:<inner_width$}"), math_style),
                            Span::styled(
                                "│".to_string(),
                                Style::default()
                                    .fg(self.tokens.syntax.code_border)
                                    .bg(self.tokens.surface.raised),
                            ),
                        ]));
                        self.current_source_lines.push(self.current_source_line);
                    }
                    // Bottom border.
                    self.lines.push(Line::from(Span::styled(
                        format!("╰{}╯", "─".repeat(inner_width + 1)),
                        border_style,
                    )));
                    self.current_source_lines.push(self.current_source_line);
                    self.push_blank_line();
                }
                _ => {}
            }
        }
        if !self.current_spans.is_empty() {
            self.flush_line();
        }
        self.flush_text_block();

        self.blocks
    }

    #[allow(clippy::too_many_lines)]
    #[allow(clippy::match_same_arms)]
    fn start_tag(&mut self, tag: Tag, span: &Range<usize>) {
        match tag {
            Tag::Heading { level, .. } => {
                self.in_heading = true;
                let color = match level {
                    pulldown_cmark::HeadingLevel::H1 => self.tokens.heading.h1,
                    pulldown_cmark::HeadingLevel::H2 => self.tokens.heading.h2,
                    pulldown_cmark::HeadingLevel::H3 => self.tokens.heading.h3,
                    _ => self.tokens.heading.other,
                };
                let mut style = Style::default().fg(color).add_modifier(Modifier::BOLD);
                if level == pulldown_cmark::HeadingLevel::H1 {
                    style = style.add_modifier(Modifier::UNDERLINED);
                }
                self.push_style(style);
                let prefix = match level {
                    pulldown_cmark::HeadingLevel::H1 => "█ ",
                    pulldown_cmark::HeadingLevel::H2 => "▌ ",
                    pulldown_cmark::HeadingLevel::H3 => "▎ ",
                    _ => "  ",
                };
                self.current_spans
                    .push(Span::styled(prefix.to_string(), self.current_style()));
            }
            Tag::Paragraph => {}
            Tag::BlockQuote(_) => {
                self.in_blockquote = true;
                self.push_style(Style::default().fg(self.tokens.list.block_quote_fg));
            }
            Tag::CodeBlock(kind) => {
                let lang = match &kind {
                    CodeBlockKind::Fenced(lang) => {
                        let s = lang.trim().to_lowercase();
                        if s.is_empty() { None } else { Some(s) }
                    }
                    CodeBlockKind::Indented => None,
                };
                self.open_verbatim_block(lang, span, matches!(kind, CodeBlockKind::Fenced(_)));
            }
            // Leading `---`/`+++` frontmatter. Accumulated exactly like a fenced
            // code block — the delimiters are not part of the event stream, so
            // `code_block_content` holds only the metadata body — and
            // highlighted with the syntax matching the delimiter style.
            Tag::MetadataBlock(kind) => {
                let lang = match kind {
                    MetadataBlockKind::YamlStyle => "yaml",
                    MetadataBlockKind::PlusesStyle => "toml",
                };
                self.open_verbatim_block(Some(lang.to_string()), span, true);
            }
            Tag::List(start) => {
                self.list_depth += 1;
                self.list_counters.push(start);
            }
            Tag::Item => {
                // Flush any content held on the still-open line before we push a
                // new bullet. Without this, the FIRST nested item under a parent
                // ends up concatenated to the parent's line (its preceding
                // `TagEnd::Item` hasn't fired yet — the parent is still mid-item,
                // with its text already in `current_spans`). Subsequent nested
                // items work because each one IS preceded by the prior sibling's
                // `TagEnd::Item` flush.
                if !self.current_spans.is_empty() {
                    // The spans held here belong to the parent's line, but
                    // `current_source_line` has already been stamped with this
                    // nested item's start. Attribute the line to where its spans
                    // were accumulated, or the parent's bullet claims the
                    // child's source line and the cursor mapping follows it
                    // there.
                    let item_line = self.current_source_line;
                    self.current_source_line = self.span_source_line;
                    self.flush_line();
                    // Back to this item's own line, which is what its bullet —
                    // pushed below — and an item with no content at all are
                    // attributed to.
                    self.current_source_line = item_line;
                }
                let indent = "  ".repeat(self.list_depth.saturating_sub(1));
                let bullet = if let Some(counter) = self.list_counters.last_mut() {
                    if let Some(n) = counter {
                        let bullet = format!("{indent}{n}. ");
                        *n += 1;
                        bullet
                    } else {
                        let marker = match self.list_depth {
                            1 => "•",
                            2 => "◦",
                            _ => "▪",
                        };
                        format!("{indent}{marker} ")
                    }
                } else {
                    format!("{indent}• ")
                };
                self.current_spans.push(Span::styled(
                    bullet,
                    Style::default().fg(self.tokens.list.marker),
                ));
            }
            Tag::Emphasis => {
                self.push_style(Style::default().add_modifier(Modifier::ITALIC));
            }
            Tag::Strong => {
                self.push_style(Style::default().add_modifier(Modifier::BOLD));
            }
            Tag::Strikethrough => {
                self.push_style(Style::default().add_modifier(Modifier::CROSSED_OUT));
            }
            Tag::Link { .. } => {
                self.in_link = true;
                self.push_style(
                    Style::default()
                        .fg(self.tokens.accent.link)
                        .add_modifier(Modifier::UNDERLINED),
                );
            }
            Tag::Image { dest_url, .. } => {
                self.in_image = true;
                self.image_as_block = !self.in_table && !self.in_heading;
                if self.image_as_block {
                    // The artwork takes the reference's place in the flow, so
                    // the text before it ends here rather than being glued to
                    // whatever follows.
                    if !self.current_spans.is_empty() {
                        let line = self.current_source_line;
                        self.current_source_line = self.span_source_line;
                        self.flush_line();
                        self.current_source_line = line;
                    }
                    self.image_dest = dest_url.to_string();
                    self.image_alt.clear();
                    self.image_source_line = self.current_source_line;
                }
            }
            Tag::Table(alignments) => {
                self.in_table = true;
                self.table_alignments = alignments;
                self.table_rows.clear();
                self.table_header_row = None;
                self.table_start_line = byte_offset_to_line(span.start, &self.line_boundaries);
                self.flush_line();
            }
            Tag::TableHead => {
                self.table_header = true;
                self.table_row.clear();
                // pulldown-cmark does NOT emit `Tag::TableRow` for a table's
                // header — the header's cells live directly inside `TableHead`.
                // Capture the source line here so `TagEnd::TableHead` has the
                // right value to push onto `table_row_source_lines`.
                self.current_table_row_source_line =
                    byte_offset_to_line(span.start, &self.line_boundaries);
            }
            Tag::TableRow => {
                self.table_row.clear();
                // Capture the source line for body rows so the caller can map a
                // display row back to the exact markdown row.
                self.current_table_row_source_line =
                    byte_offset_to_line(span.start, &self.line_boundaries);
            }
            Tag::TableCell => {}
            _ => {}
        }
    }

    fn end_tag(&mut self, tag: TagEnd, span: &Range<usize>) {
        match tag {
            TagEnd::Heading(_) => {
                self.pop_style();
                self.flush_line();
                // Blank line is part of this heading's block (visual separator),
                // then flush so each heading gets its own DocBlock::Text.
                self.push_blank_line();
                self.flush_text_block();
                self.in_heading = false;
            }
            TagEnd::Paragraph => {
                // A paragraph that ended on an image has no trailing spans —
                // the image block already ended the line — and flushing the
                // empty ones would leave a second blank row under the artwork.
                if !self.current_spans.is_empty() || !self.after_image_block {
                    self.flush_line();
                }
                self.after_image_block = false;
                // Blank line belongs to this paragraph's block, then flush so
                // each paragraph is a separate DocBlock::Text.
                self.push_blank_line();
                self.flush_text_block();
            }
            TagEnd::BlockQuote(_) => {
                self.in_blockquote = false;
                self.pop_style();
                // Blank line belongs to this blockquote's block, then flush so
                // each blockquote is a separate DocBlock::Text.
                self.push_blank_line();
                self.flush_text_block();
            }
            TagEnd::CodeBlock => {
                let lang = self.code_block_lang.as_deref();
                let is_mermaid = lang == Some("mermaid")
                    || (lang.is_none_or(str::is_empty)
                        && looks_like_mermaid(&self.code_block_content));
                // Advance `current_source_line` past the closing fence before
                // emitting. Without this, the trailing `push_blank_line()` in
                // `emit_mermaid_block` (and the subsequent text block's first
                // `source_lines` entry) would anchor at the last diagram-content
                // line.
                //
                // pulldown-cmark's End(CodeBlock) span ends at the byte just
                // past the closing fence's last backtick (excluding the trailing
                // newline). `span.end - 1` is therefore the last byte of the
                // closing fence; its line is the closing-fence line. The line
                // *after* the closing fence is the right anchor for the trailing
                // `push_blank_line()`.
                let closing_fence_line =
                    byte_offset_to_line(span.end.saturating_sub(1), &self.line_boundaries);
                self.current_source_line = closing_fence_line.saturating_add(1);
                if is_mermaid {
                    self.emit_mermaid_block();
                } else {
                    self.render_code_block(None);
                    // Flush so each fenced code block is its own DocBlock::Text.
                    // `render_code_block` already appended the trailing blank
                    // line (visual separator), so the blank is part of this
                    // block. Mermaid already flushes inside
                    // `emit_mermaid_block`.
                    self.flush_text_block();
                }
                self.in_code_block = false;
                self.code_block_lang = None;
            }
            TagEnd::MetadataBlock(_) => {
                // `span.end` is the byte just past the closing delimiter, so the
                // next block's source anchor is the line after it — same
                // reasoning as `TagEnd::CodeBlock` above.
                let closing_line =
                    byte_offset_to_line(span.end.saturating_sub(1), &self.line_boundaries);
                self.current_source_line = closing_line.saturating_add(1);
                self.render_code_block(Some(FRONTMATTER_LABEL));
                self.flush_text_block();
                self.in_code_block = false;
                self.code_block_lang = None;
            }
            TagEnd::List(_) => {
                self.list_depth = self.list_depth.saturating_sub(1);
                self.list_counters.pop();
                if self.list_depth == 0 {
                    // Blank line belongs to this list's block, then flush so the
                    // outermost list is its own DocBlock::Text. Nested list
                    // closes (list_depth > 0 after decrement) must NOT flush —
                    // nested lists stay in a single block with their parent.
                    self.push_blank_line();
                    self.flush_text_block();
                }
            }
            TagEnd::Item => {
                self.flush_line();
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => {
                self.pop_style();
            }
            TagEnd::Link => {
                self.in_link = false;
                self.pop_style();
            }
            TagEnd::Image => {
                self.in_image = false;
                if self.image_as_block {
                    self.image_as_block = false;
                    // The text before the image is a block of its own, then the
                    // image block, in that order.
                    self.flush_text_block();
                    self.blocks.push(DocBlock::Image {
                        dest: std::mem::take(&mut self.image_dest),
                        alt: std::mem::take(&mut self.image_alt),
                        source_line: self.image_source_line,
                    });
                    self.after_image_block = true;
                }
            }
            TagEnd::Table => {
                self.emit_table_block();
                self.in_table = false;
            }
            TagEnd::TableHead => {
                self.table_header_row = Some(self.table_row.clone());
                // Record the header row's source line before clearing the flag.
                self.table_row_source_lines
                    .push(self.current_table_row_source_line);
                self.table_header = false;
            }
            TagEnd::TableRow if !self.table_header => {
                self.table_rows.push(self.table_row.clone());
                // Record the body row's source line (the header is already
                // recorded in TagEnd::TableHead above).
                self.table_row_source_lines
                    .push(self.current_table_row_source_line);
            }
            TagEnd::TableCell => {
                let cell_spans: CellSpans = std::mem::take(&mut self.current_spans);
                self.table_row.push(cell_spans);
            }
            _ => {}
        }
    }

    /// Begin accumulating a verbatim (non-markdown) block: a fenced/indented
    /// code block or a frontmatter metadata block.
    ///
    /// Both feed their body through `Event::Text` and both are closed by
    /// `render_code_block`, so they share this entry point rather than
    /// duplicating the bookkeeping. `span` is the opening tag's byte range.
    ///
    /// `fenced` distinguishes the two shapes a code block can take. A fenced
    /// block's `span.start` is the opening delimiter, so its first content line
    /// is one further down; an indented block has no delimiter and its
    /// `span.start` is already the first content line. Guessing from the
    /// language would be wrong for an untagged fence.
    fn open_verbatim_block(&mut self, lang: Option<String>, span: &Range<usize>, fenced: bool) {
        self.in_code_block = true;
        self.code_block_lang = lang;
        self.code_block_fenced = fenced;
        self.code_block_content.clear();
        // Resolve the fence's source line.
        self.code_block_start_line = byte_offset_to_line(span.start, &self.line_boundaries);
        // Only flush if there are pending inline spans — an unconditional
        // flush_line() would push an empty line into self.lines, which then
        // creates a spurious empty DocBlock::Text when the preceding element
        // already called flush_text_block() (per-element granularity).
        if !self.current_spans.is_empty() {
            self.flush_line();
        }
    }

    fn handle_text(&mut self, text: &str) {
        if self.in_image && self.image_as_block {
            // Alt text is not body text: it belongs to the reference, ready to
            // stand in for the image if the image cannot be drawn.
            self.after_image_block = false;
            self.image_alt
                .push(Span::styled(text.to_string(), self.current_style()));
        } else if self.in_code_block {
            for line in text.split('\n') {
                self.code_block_content.push(line.to_string());
            }
            if self.code_block_content.last().is_some_and(String::is_empty) {
                self.code_block_content.pop();
            }
        } else {
            self.current_spans
                .push(Span::styled(text.to_string(), self.current_style()));
        }
    }

    /// Flush accumulated code lines as a `DocBlock::Mermaid`, preceded by any
    /// pending text lines as a `DocBlock::Text`.
    fn emit_mermaid_block(&mut self) {
        self.flush_text_block();

        let source = self.code_block_content.join("\n");
        self.code_block_content.clear();

        self.blocks.push(DocBlock::Mermaid {
            source,
            // The fence line is the canonical source position for the block.
            source_line: self.code_block_start_line,
        });
        // Blank line after the diagram (will open a new Text block).
        self.push_blank_line();
    }

    /// Render the accumulated verbatim block as a syntax-highlighted box.
    ///
    /// `label`, when present, is drawn into the top border (e.g.
    /// [`FRONTMATTER_LABEL`]) so the box announces what it holds. It must
    /// include its own surrounding spaces and be ASCII — the border arithmetic
    /// counts bytes.
    fn render_code_block(&mut self, label: Option<&str>) {
        // `tokens.syntax.code_border` — the chrome colour for fenced code boxes.
        let border_style = Style::default().fg(self.tokens.syntax.code_border);

        // Capture the fence's source line before any mutable borrows below.
        let code_start_line = self.code_block_start_line;
        // Content line i of a fenced block sits on `start + 1 + i`; an indented
        // block starts its content on `start` itself.
        let content_offset: u32 = if self.code_block_fenced { 1 } else { 0 };

        // Widths are measured in display cells, not bytes, so that lines
        // containing multi-byte characters (em dashes, CJK, emoji, …) align with
        // the box frame drawn around them.
        let max_width = self
            .code_block_content
            .iter()
            .map(|l| UnicodeWidthStr::width(l.as_str()))
            .max()
            .unwrap_or(0)
            .max(20)
            // A label is drawn inside the top border, so the box has to be at
            // least wide enough to hold it or the top and bottom borders would
            // disagree on width.
            .max(label.map_or(0, str::len));
        let inner_width = max_width + 1;

        // Join lines with newlines so syntect sees a complete source text.
        // highlight_code returns one TokenLine per source line.
        let source = self.code_block_content.join("\n");
        let token_lines = crate::highlight::highlight_code(
            &source,
            self.code_block_lang.as_deref(),
            self.syntax_theme_name,
            // `tokens.syntax.code_fg` — default foreground for unhighlighted
            // tokens.
            self.tokens.syntax.code_fg,
            // `tokens.surface.raised` — code blocks share the raised surface
            // tier with popups and the status bar.
            self.tokens.surface.raised,
        );

        // Blank line before the box. It anchors to the block's own opening
        // line, not to whatever `current_source_line` holds: the caller has
        // already advanced that past the closing delimiter, and a blank
        // claiming a *later* source line than the border that follows it would
        // make the anchors non-monotone, which `build_source_map`'s forward
        // scan cannot represent.
        let restore_line = std::mem::replace(&mut self.current_source_line, code_start_line);
        self.push_blank_line();
        self.current_source_line = restore_line;

        // Top border maps to the fence line. With a label the rule is split
        // around it; the total width is identical either way so the top and
        // bottom borders always line up.
        self.lines.push(match label {
            None => Line::from(Span::styled(
                format!("╭{}╮", "─".repeat(inner_width + 1)),
                border_style,
            )),
            Some(label) => Line::from(vec![
                Span::styled("╭".to_string(), border_style),
                Span::styled(
                    label.to_string(),
                    Style::default()
                        .fg(self.tokens.syntax.inline_code)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(
                        "{}╮",
                        "─".repeat((inner_width + 1).saturating_sub(label.len()))
                    ),
                    border_style,
                ),
            ]),
        });
        self.current_source_lines.push(code_start_line);

        // One rendered line per source line.
        // Layout per line: "│ " <highlighted tokens padded to inner_width> "│"
        //
        // The tokens together have `line.len()` visible bytes. We pad the gap
        // between the last token and the right border with spaces using the same
        // background colour, so the box aligns regardless of token count.
        for (i, (src_line, token_line)) in self
            .code_block_content
            .iter()
            .zip(token_lines.iter())
            .enumerate()
        {
            let line_width = UnicodeWidthStr::width(src_line.as_str());
            let pad_len = inner_width.saturating_sub(line_width);

            let mut spans: Vec<Span> = Vec::with_capacity(token_line.len() + 3);

            // Left border + leading space (border colour for `│`,
            // surface.raised for the space so it blends with the token
            // background).
            spans.push(Span::styled(
                "│ ".to_string(),
                Style::default()
                    .fg(self.tokens.syntax.code_border)
                    .bg(self.tokens.surface.raised),
            ));

            // Syntax-highlighted token spans.
            for (text, style) in token_line {
                spans.push(Span::styled(text.clone(), *style));
            }

            // Padding to align the right border.
            if pad_len > 0 {
                spans.push(Span::styled(
                    " ".repeat(pad_len),
                    Style::default().bg(self.tokens.surface.raised),
                ));
            }

            // Right border.
            spans.push(Span::styled(
                "│".to_string(),
                Style::default()
                    .fg(self.tokens.syntax.code_border)
                    .bg(self.tokens.surface.raised),
            ));

            self.lines.push(Line::from(spans));
            // Content line i (0-indexed), offset past the delimiter when there
            // is one.
            self.current_source_lines
                .push(code_start_line + content_offset + crate::cast::u32_sat(i));
        }

        // Bottom border maps to the line after the last content line.
        let bottom_source_line =
            code_start_line + content_offset + crate::cast::u32_sat(self.code_block_content.len());
        self.lines.push(Line::from(Span::styled(
            format!("╰{}╯", "─".repeat(inner_width + 1)),
            border_style,
        )));
        self.current_source_lines.push(bottom_source_line);

        self.code_block_content.clear();
        self.push_blank_line();
    }

    fn emit_table_block(&mut self) {
        let headers = self.table_header_row.take().unwrap_or_default();
        let rows = std::mem::take(&mut self.table_rows);
        let row_source_lines = std::mem::take(&mut self.table_row_source_lines);
        let alignments = std::mem::take(&mut self.table_alignments);

        let num_cols = headers
            .len()
            .max(rows.iter().map(Vec::len).max().unwrap_or(0));

        if num_cols == 0 {
            return;
        }

        let mut natural_widths = vec![0usize; num_cols];
        for (i, cell) in headers.iter().enumerate() {
            natural_widths[i] = natural_widths[i].max(crate::text_layout::measure(cell) as usize);
        }
        for row in &rows {
            for (i, cell) in row.iter().enumerate() {
                if i < num_cols {
                    natural_widths[i] =
                        natural_widths[i].max(crate::text_layout::measure(cell) as usize);
                }
            }
        }
        // Minimum column width of 1 so borders are always valid.
        for w in &mut natural_widths {
            *w = (*w).max(1);
        }

        self.flush_text_block();
        self.blocks.push(DocBlock::Table(TableBlock {
            headers,
            rows,
            alignments,
            natural_widths,
            source_line: self.table_start_line,
            row_source_lines,
        }));
        self.push_blank_line();
    }
}

/// Heuristic: does an untagged code block look like Mermaid source?
///
/// Triggered for backtick fences with no language tag (a common authoring
/// mistake — the user expected ` ```mermaid ` to render the diagram). We match
/// on the first non-empty line starting with one of Mermaid's
/// diagram-declaration keywords AND followed by mermaid-typical syntax — for
/// `graph`/`flowchart` that means a direction token (TD/TB/BT/LR/RL); for the
/// others a colon or whitespace+identifier is enough. This avoids false
/// positives on legitimate JS/TS lines like `graph = {};` or
/// `import { graph }`.
fn looks_like_mermaid(content: &[String]) -> bool {
    let first = content
        .iter()
        .find(|line| !line.trim().is_empty())
        .map(|s| s.trim().to_string())
        .unwrap_or_default();

    // Diagrams that take a flow direction as the next token.
    const DIRECTIONAL: &[&str] = &["graph", "flowchart"];
    const DIRECTIONS: &[&str] = &["TD", "TB", "BT", "LR", "RL"];
    for kw in DIRECTIONAL {
        if let Some(rest) = first.strip_prefix(kw) {
            // After the keyword we expect whitespace + a direction (most
            // common), or a semicolon (compact one-line form
            // `graph LR; A --> B`). Reject anything else — `graph =` and
            // friends fall through here.
            let rest = rest.trim_start();
            for dir in DIRECTIONS {
                if rest == *dir
                    || rest.starts_with(&format!("{dir} "))
                    || rest.starts_with(&format!("{dir};"))
                {
                    return true;
                }
            }
            return false;
        }
    }

    // Diagrams whose declaration keyword stands alone on the first line. Strict
    // equality (no trailing chars) to avoid catching English sentences like
    // "sequenceDiagram is great". Users who write the rare single-line variants
    // (e.g. `pie title Pets`) need to add the explicit ` ```mermaid ` tag —
    // that's a fair ask for an unambiguous heuristic.
    const STANDALONE: &[&str] = &[
        "sequenceDiagram",
        "stateDiagram-v2",
        "stateDiagram",
        "erDiagram",
        "classDiagram",
        "pie",
        "gantt",
        "journey",
        "gitGraph",
        "mindmap",
        "timeline",
        "quadrantChart",
        "requirementDiagram",
        "C4Context",
        "C4Container",
        "C4Component",
        "C4Dynamic",
    ];
    if STANDALONE.iter().any(|kw| first == *kw) {
        return true;
    }
    // For `pie`-style declarations that put the title on the same line, also
    // accept the pattern `pie title "..."` and `pie showData ...` since those
    // are common Mermaid forms.
    if first.starts_with("pie title ")
        || first.starts_with("pie showData")
        || first.starts_with("gantt dateFormat ")
    {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme::{Palette, Theme};

    /// The blocks a document renders to, under the default theme.
    fn blocks(content: &str) -> Vec<DocBlock> {
        render_markdown(content, &Palette::default(), Theme::default())
    }

    /// Each block as a word: what kind of thing the document turned into.
    fn kinds(blocks: &[DocBlock]) -> Vec<&'static str> {
        blocks
            .iter()
            .map(|block| match block {
                DocBlock::Text { .. } => "text",
                DocBlock::Table(_) => "table",
                DocBlock::Mermaid { .. } => "mermaid",
                DocBlock::Image { .. } => "image",
            })
            .collect()
    }

    /// Every `Text` block's text, one display line per line.
    fn text_of(blocks: &[DocBlock]) -> String {
        blocks
            .iter()
            .filter_map(|block| match block {
                DocBlock::Text { text, .. } => Some(
                    text.lines
                        .iter()
                        .map(Line::text)
                        .collect::<Vec<_>>()
                        .join("\n"),
                ),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The alt text an image block carries.
    fn alt_of(block: &DocBlock) -> String {
        match block {
            DocBlock::Image { alt, .. } => alt.iter().map(|span| span.content.as_str()).collect(),
            other => panic!("expected an image block, got {other:?}"),
        }
    }

    #[test]
    fn an_image_mid_paragraph_splits_the_text_around_it() {
        let blocks = blocks("text before ![alt](x.png) text after");

        assert_eq!(kinds(&blocks), ["text", "image", "text"]);
        assert_eq!(alt_of(&blocks[1]), "alt");
        // The alt text is not also body text.
        let text = text_of(&blocks);
        assert!(text.contains("text before"), "{text:?}");
        assert!(text.contains("text after"), "{text:?}");
        assert!(!text.contains("alt"), "{text:?}");
    }

    #[test]
    fn an_image_is_anchored_at_its_own_reference() {
        let blocks = blocks("# Title\n\n![alt](x.png)\n");

        let images: Vec<&DocBlock> = blocks
            .iter()
            .filter(|block| matches!(block, DocBlock::Image { .. }))
            .collect();
        assert_eq!(images.len(), 1, "{blocks:?}");

        match images[0] {
            DocBlock::Image { source_line, .. } => assert_eq!(*source_line, 2),
            other => panic!("expected an image block, got {other:?}"),
        }
        assert!(!text_of(&blocks).contains("alt"), "{blocks:?}");
    }

    #[test]
    fn an_image_inside_a_table_cell_stays_alt_text() {
        // A cell holds spans, not blocks: a table's columns are sized from its
        // cells, so there is nowhere for a block of artwork to go.
        let blocks = blocks("| a | b |\n| - | - |\n| ![alt](x.png) | y |\n");

        assert_eq!(kinds(&blocks), ["table"]);
        assert!(
            text_of(&blocks).is_empty(),
            "a table is not a text block: {blocks:?}"
        );
        match &blocks[0] {
            DocBlock::Table(table) => {
                let cell: String = table.rows[0][0]
                    .iter()
                    .map(|span| span.content.as_str())
                    .collect();
                assert_eq!(cell, "alt");
            }
            other => panic!("expected a table, got {other:?}"),
        }
    }

    #[test]
    fn an_image_inside_a_heading_stays_alt_text() {
        // A heading is one line: the reference keeps the alt text it always
        // had rather than pushing the heading's own line apart.
        let blocks = blocks("# ![alt](x.png)");

        assert_eq!(kinds(&blocks), ["text"]);
        assert!(text_of(&blocks).contains("alt"), "{blocks:?}");
    }
}
