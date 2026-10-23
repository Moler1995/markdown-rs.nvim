//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
//!
//! Width-aware span wrapping and measurement.
//!
//! # Departure from the origin
//!
//! [`wrap_spans`] drops a character whose display width exceeds `max_width`
//! outright. The origin placed such a character on a row of its own, which
//! produced both a row wider than the budget and a spurious empty row before
//! it. The origin never hit this — it laid out to a real terminal's width —
//! but the engine's width guarantee is unconditional, so the character is
//! dropped rather than allowed to overflow.
//!
//! This module is the **single source of truth** for display-width calculation
//! over span lists. All other code in the crate that needs to know how wide a
//! sequence of styled spans is, or how many visual rows it occupies at a given
//! width, should call [`measure`] or [`wrap_spans`] rather than recomputing
//! widths inline.
//!
//! # Algorithm
//!
//! [`wrap_spans`] implements greedy word-wrap ported verbatim from
//! `src/ui/table_modal::wrap_cell_spans`, which is battle-tested against the
//! full range of span styles. The steps are:
//!
//! 1. Flatten the span list to a sequence of `(char, display_width, Style)`
//!    triples, preserving per-char style.
//! 2. Split on hard `'\n'` characters to produce *hard lines*.
//! 3. Within each hard line, split on whitespace to produce *words*.
//! 4. Greedily pack words onto output rows; start a new row when a word won't
//!    fit. Words wider than `max_width` are hard-split character-by-character
//!    so every output row is guaranteed `≤ max_width` columns. Combining marks
//!    (zero-width chars) stay attached to their base char for free since a
//!    wrap boundary only fires when the next non-zero-width char would push
//!    the row past `max_width`.
//! 5. Adjacent same-style characters on the same output row are merged into a
//!    single [`WrappedSpan`].
//!
//! # Whitespace at wrap points
//!
//! Inter-word whitespace at wrap points is **consumed**: the space between the
//! last word of a row and the first word of the next row is dropped. That keeps
//! column-width accounting exact and avoids phantom indentation on continuation
//! rows. A line that already fits is emitted verbatim instead — word-splitting
//! would collapse multi-space gaps, and inside a code block those gaps are
//! load-bearing.

use unicode_width::UnicodeWidthChar;

use crate::style::{Line, Span, Style};

// ── Public types ─────────────────────────────────────────────────────────────

/// A single styled chunk of text on one visual row, with its display width
/// pre-computed and cached.
///
/// `content` is owned because [`wrap_spans`] always synthesises new content
/// from the input span character stream — there is no zero-copy path to
/// preserve borrows from the source spans. Keeping the type owned makes the
/// allocation explicit at the call site.
///
/// `width` is a saturating cast from `usize` to `u16`; values that would exceed
/// `u16::MAX` (≈65 535 columns) are clamped. In practice no terminal is that
/// wide.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WrappedSpan {
    /// The text content of this span chunk.
    pub content: String,
    /// The style applied to every character in `content`.
    pub style: Style,
    /// Pre-computed display width in columns.
    pub width: u16,
}

/// A single visual output row produced by [`wrap_spans`].
///
/// Each `WrappedLine` is one display row: no embedded newlines, guaranteed
/// `≤ max_width` columns. The cached `width` equals
/// `spans.iter().map(|s| s.width).sum()`, which avoids re-scanning the content
/// for width on every layout pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WrappedLine {
    /// Ordered sequence of styled span chunks on this row.
    pub spans: Vec<WrappedSpan>,
    /// Total display width of the row: `spans.iter().map(|s| s.width).sum()`.
    pub width: u16,
}

impl WrappedLine {
    /// Convert to a [`Line`] ready to place in a buffer. Each [`WrappedSpan`]
    /// becomes a `Span::styled(content.clone(), style)`.
    #[must_use]
    pub fn to_line(&self) -> Line {
        Line::from(
            self.spans
                .iter()
                .map(|ws| Span::styled(ws.content.clone(), ws.style))
                .collect::<Vec<_>>(),
        )
    }
}

// ── Public functions ─────────────────────────────────────────────────────────

/// Greedy word-wrap of `spans` to fit within `max_width` display columns.
///
/// # Behaviour
///
/// - Always returns **at least one** element. Empty input → one empty row.
/// - Hard `'\n'` characters inside any span force a row boundary; the `'\n'`
///   itself is consumed (not present on either side of the split).
/// - Inter-word whitespace at wrap points is **consumed** (see module docs).
/// - Words wider than `max_width` are hard-split character-by-character. Every
///   output row is guaranteed `width ≤ max_width`. Combining marks (zero-width
///   chars) stay attached to their base char.
/// - `max_width == 0` short-circuits to one output row per hard line, each with
///   an empty `spans` vec and `width == 0`.
#[must_use]
pub fn wrap_spans(spans: &[Span], max_width: u16) -> Vec<WrappedLine> {
    // Short-circuit: width 0 means "no wrapping info available yet"; emit one
    // empty row per hard line so callers can count logical lines.
    if max_width == 0 {
        let n = hard_line_count(spans).max(1);
        return (0..n)
            .map(|_| WrappedLine {
                spans: vec![],
                width: 0,
            })
            .collect();
    }

    // Flatten all spans to (char, char_width, Style) triples, preserving style.
    let styled: Vec<(char, usize, Style)> = spans
        .iter()
        .flat_map(|span| {
            let style = span.style;
            span.content.chars().map(move |ch| {
                let w = UnicodeWidthChar::width(ch).unwrap_or(0);
                (ch, w, style)
            })
        })
        .collect();

    if styled.is_empty() {
        return vec![WrappedLine {
            spans: vec![],
            width: 0,
        }];
    }

    let max = max_width as usize;
    let mut result: Vec<WrappedLine> = Vec::new();

    // Iterate over hard lines delimited by '\n'.
    let mut line_start = 0usize;
    loop {
        let line_end = styled[line_start..]
            .iter()
            .position(|(ch, _, _)| *ch == '\n')
            .map_or(styled.len(), |p| line_start + p);

        emit_wrapped_hard_line(&styled[line_start..line_end], max, &mut result);

        if line_end >= styled.len() {
            break;
        }
        line_start = line_end + 1;
    }

    if result.is_empty() {
        result.push(WrappedLine {
            spans: vec![],
            width: 0,
        });
    }
    result
}

/// Total display width (in columns) of a span list.
///
/// Equivalent to calling [`wrap_spans`] on a single-line input and reading
/// `result[0].width`, but faster — O(n) without any allocation.
///
/// Returns `0` for an empty span list. The result is a saturating cast to
/// `u16`; values exceeding 65 535 columns are clamped.
#[must_use]
pub fn measure(spans: &[Span]) -> u16 {
    let total: usize = spans
        .iter()
        .map(|s| unicode_width::UnicodeWidthStr::width(s.content.as_str()))
        .sum();
    crate::cast::u16_sat(total)
}

// ── Private helpers ──────────────────────────────────────────────────────────

/// Count the number of hard lines (newline-delimited segments) in `spans`.
///
/// Used by the `max_width == 0` short-circuit to produce the correct number of
/// empty output rows — one per hard line, or one if there are no newlines.
fn hard_line_count(spans: &[Span]) -> usize {
    spans
        .iter()
        .flat_map(|s| s.content.chars())
        .filter(|&ch| ch == '\n')
        .count()
        + 1
}

/// Wrap a single hard line (guaranteed no embedded `'\n'`) and push output rows
/// to `out`.
///
/// This is the core greedy-packing routine. The algorithm:
///
/// 1. Collect whitespace-separated word slices from the flat char list.
/// 2. For each word:
///    - If it fits on the current row (with space separator if needed), append.
///    - If it doesn't fit, flush the current row and start a new one.
///    - If the word itself is wider than `max_width`, hard-split it
///      character-by-character. Combining marks (zero-width chars) stay
///      attached to their base char for free: a wrap boundary only fires when
///      `chunk_w + cw > max_width`, and that is never true for `cw == 0`.
fn emit_wrapped_hard_line(
    chars: &[(char, usize, Style)],
    max_width: usize,
    out: &mut Vec<WrappedLine>,
) {
    // Short-circuit: if the whole line already fits, emit it verbatim (no
    // whitespace splitting). Word-splitting collapses multi-space gaps to
    // single spaces — fine for prose, wrong for pre-formatted ASCII art inside
    // code blocks, where alignment between rows is load-bearing (e.g.
    // box-drawing borders that must sit directly above their middle row's text).
    let total_w: usize = chars.iter().map(|(_, w, _)| w).sum();
    if total_w <= max_width {
        if chars.is_empty() {
            out.push(WrappedLine {
                spans: vec![],
                width: 0,
            });
        } else {
            let pairs: Vec<(char, Style)> = chars.iter().map(|&(c, _, s)| (c, s)).collect();
            out.push(pack_row(&pairs));
        }
        return;
    }

    // Split into whitespace-separated words (slices of the input triple vec).
    let mut words: Vec<&[(char, usize, Style)]> = Vec::new();
    let mut word_start: Option<usize> = None;
    for (i, (ch, _, _)) in chars.iter().enumerate() {
        if ch.is_whitespace() {
            if let Some(start) = word_start.take() {
                words.push(&chars[start..i]);
            }
        } else if word_start.is_none() {
            word_start = Some(i);
        }
    }
    if let Some(start) = word_start {
        words.push(&chars[start..]);
    }

    if words.is_empty() {
        out.push(WrappedLine {
            spans: vec![],
            width: 0,
        });
        return;
    }

    // Accumulator for the current output row: (char, Style) pairs.
    let mut row_buf: Vec<(char, Style)> = Vec::new();
    let mut row_w = 0usize;

    for word in &words {
        let word_w: usize = word.iter().map(|(_, w, _)| w).sum();

        if word_w <= max_width {
            // Word fits on one row.
            if row_w > 0 && row_w + 1 + word_w > max_width {
                // Flush current row; this word starts the next one.
                out.push(pack_row(&row_buf));
                row_buf.clear();
                row_w = 0;
            }
            if row_w > 0 {
                // Insert inter-word space using the word's first char style.
                let space_style = word.first().map(|(_, _, s)| *s).unwrap_or_default();
                row_buf.push((' ', space_style));
                row_w += 1;
            }
            for &(ch, cw, style) in *word {
                row_buf.push((ch, style));
                row_w += cw;
            }
        } else {
            // Word is wider than max_width — hard-split at char boundaries.
            // This keeps combining marks (which have width 0) attached to their
            // base char for free: a wrap boundary only fires when `chunk_w + cw
            // > max_width`, and that is never true for `cw == 0`.
            if row_w > 0 {
                out.push(pack_row(&row_buf));
                row_buf.clear();
            }
            let mut chunk_w: usize = 0;
            for &(ch, cw, style) in *word {
                // A character wider than the entire budget can never be placed
                // on any row. The origin emitted it anyway, which produced a
                // row wider than `max_width` plus a spurious empty row before
                // it (the flush fired with `chunk_w == 0`). The width guarantee
                // is what callers size their windows against, so the character
                // is dropped instead of allowed to overflow.
                if cw > max_width {
                    continue;
                }
                if chunk_w + cw > max_width {
                    out.push(pack_row(&row_buf));
                    row_buf.clear();
                    chunk_w = 0;
                }
                row_buf.push((ch, style));
                chunk_w += cw;
            }
            row_w = chunk_w;
        }
    }

    if !row_buf.is_empty() {
        out.push(pack_row(&row_buf));
    }
}

/// Pack a `(char, Style)` buffer into a [`WrappedLine`], merging adjacent
/// same-style chars into single [`WrappedSpan`] values.
fn pack_row(pairs: &[(char, Style)]) -> WrappedLine {
    let mut spans: Vec<WrappedSpan> = Vec::new();
    let mut row_width: u16 = 0;

    for &(ch, style) in pairs {
        let ch_w = crate::cast::u16_sat(UnicodeWidthChar::width(ch).unwrap_or(0));
        row_width = row_width.saturating_add(ch_w);

        if let Some(last) = spans.last_mut()
            && last.style == style
        {
            // Extend the existing span in-place — adjacent same-style chars
            // become one span.
            last.content.push(ch);
            last.width = last.width.saturating_add(ch_w);
        } else {
            spans.push(WrappedSpan {
                content: ch.to_string(),
                style,
                width: ch_w,
            });
        }
    }

    WrappedLine {
        spans,
        width: row_width,
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::style::Modifier;

    // ── helpers ──────────────────────────────────────────────────────────────

    fn raw(s: impl Into<String>) -> Span {
        Span::raw(s.into())
    }

    fn styled(s: impl Into<String>, style: Style) -> Span {
        Span::styled(s.into(), style)
    }

    fn bold() -> Style {
        Style::default().add_modifier(Modifier::BOLD)
    }

    fn italic() -> Style {
        Style::default().add_modifier(Modifier::ITALIC)
    }

    /// Pre-formatted ASCII art (e.g. a code-block diagram) must keep its
    /// inter-word whitespace exactly when the line fits — collapsing
    /// multi-space gaps to single spaces would misalign the box-drawing borders
    /// with the text row beneath them, making boxes look like they have no
    /// top/bottom borders.
    #[test]
    fn wrap_spans_preserves_multispace_when_line_fits() {
        let line = "┌───────┐      ┌──────┐      ┌────────┐";
        let rows = wrap_spans(&[Span::raw(line)], 80);
        assert_eq!(rows.len(), 1);
        let s: String = rows[0].spans.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(s, line, "multi-space gaps must be preserved verbatim");
    }

    /// Assert every row in `rows` has `row.width ≤ max_width` and that
    /// `row.width` matches the recomputed sum of span widths.
    fn assert_invariants(rows: &[WrappedLine], max_width: u16) {
        for (i, row) in rows.iter().enumerate() {
            let recomputed: u16 = row.spans.iter().map(|s| s.width).sum();
            assert_eq!(
                recomputed,
                row.width,
                "row {i}: cached width {w} != recomputed {recomputed}",
                w = row.width
            );
            if max_width > 0 {
                assert!(
                    row.width <= max_width,
                    "row {i} width {w} exceeds max_width {max_width}",
                    w = row.width
                );
            }
        }
    }

    /// Run `f` over several widths and assert the basic invariants each time.
    fn at_widths<F>(widths: &[u16], mut f: F)
    where
        F: FnMut(u16) -> Vec<WrappedLine>,
    {
        for &w in widths {
            let rows = f(w);
            assert!(!rows.is_empty(), "wrap_spans must never return empty vec");
            assert_invariants(&rows, w);
        }
    }

    /// Flatten soft-wrapped rows back to a single-line span list.
    ///
    /// Joins rows with a single space — the inter-word whitespace `wrap_spans`
    /// consumes at soft-wrap boundaries. **Only valid for inputs without hard
    /// newlines**: a `'\n'` is consumed at hard breaks too, but the boundary is
    /// semantically a line break, not a space, and re-wrapping the flattened
    /// form would land row breaks at different points.
    fn flatten_soft_wrapped(rows: &[WrappedLine]) -> Vec<Span> {
        let mut out: Vec<Span> = Vec::new();
        for (i, row) in rows.iter().enumerate() {
            if i > 0 {
                out.push(raw(" "));
            }
            for ws in &row.spans {
                out.push(Span::styled(ws.content.clone(), ws.style));
            }
        }
        out
    }

    // ── case 1: empty input ──────────────────────────────────────────────────

    #[test]
    fn empty_input_yields_one_empty_row() {
        let rows = wrap_spans(&[], 80);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].spans, vec![]);
        assert_eq!(rows[0].width, 0);
    }

    // ── case 2: single short word ────────────────────────────────────────────

    #[test]
    fn single_short_word_one_row() {
        let rows = wrap_spans(&[raw("hello")], 80);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].width, 5);
    }

    // ── case 3: oversize word — hard-split at char boundaries ────────────────

    #[test]
    fn oversize_word_hard_split() {
        let widths = [20u16, 40, 60, 80, 120, 200];
        at_widths(&widths, |w| {
            let word = "a".repeat(300);
            wrap_spans(&[raw(&word)], w)
        });
        // Also verify the split at narrow width specifically.
        let rows = wrap_spans(&[raw("abcdefghij")], 4);
        assert!(rows.len() >= 2, "long word must hard-split: {rows:?}");
        for row in &rows {
            assert!(row.width <= 4, "row too wide: {}", row.width);
        }
        // No content lost.
        let total: String = rows
            .iter()
            .flat_map(|r| r.spans.iter())
            .map(|s| s.content.as_str())
            .collect();
        assert_eq!(total, "abcdefghij");
    }

    // ── case 4: two words that fit exactly ───────────────────────────────────

    #[test]
    fn two_words_fit_exactly_one_row() {
        // "ab cd" = 5 cols; max_width = 5 → must fit on one row.
        let rows = wrap_spans(&[raw("ab cd")], 5);
        assert_eq!(rows.len(), 1, "should be one row: {rows:?}");
        assert_eq!(rows[0].width, 5);
    }

    // ── case 5: second word forces wrap ──────────────────────────────────────

    #[test]
    fn second_word_forces_wrap() {
        let widths = [20u16, 40, 60, 80, 120, 200];
        at_widths(&widths, |w| {
            // First word fills the row completely; second word must go to row 2.
            let first = "a".repeat(w as usize);
            let second = "b".repeat(w as usize);
            let input = format!("{first} {second}");
            wrap_spans(&[raw(&input)], w)
        });

        // Concrete narrow case.
        let rows = wrap_spans(&[raw("hello world")], 8);
        assert_eq!(rows.len(), 2, "second word must wrap: {rows:?}");
        // Inter-word space consumed, not carried to the next row.
        let second_row_text: String = rows[1].spans.iter().map(|s| s.content.as_str()).collect();
        assert!(
            !second_row_text.starts_with(' '),
            "leading space must be consumed"
        );
    }

    // ── case 6: hard newline mid-span ────────────────────────────────────────

    #[test]
    fn hard_newline_mid_span_forces_break() {
        let b = bold();
        let spans = [styled("first\nsecond", b)];
        let rows = wrap_spans(&spans, 80);
        assert_eq!(rows.len(), 2, "\\n must split into two rows: {rows:?}");
        // Both halves keep the bold style.
        for row in &rows {
            for ws in &row.spans {
                assert_eq!(ws.style, b, "style must be preserved across newline");
            }
        }
        // Content is intact on each side.
        let first_text: String = rows[0].spans.iter().map(|s| s.content.as_str()).collect();
        let second_text: String = rows[1].spans.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(first_text, "first");
        assert_eq!(second_text, "second");
    }

    // ── case 7: mixed styles within a word ───────────────────────────────────

    #[test]
    fn mixed_styles_within_word_preserved_on_split() {
        let widths = [20u16, 40, 60, 80, 120, 200];
        at_widths(&widths, |w| {
            // A "word" composed of two adjacent styled spans (no space between).
            let spans = [styled("AAAA", bold()), styled("BBBB", italic())];
            wrap_spans(&spans, w)
        });

        // Narrow case: 3-col width forces a hard split inside the word.
        let spans = [styled("AAA", bold()), styled("BBB", italic())];
        let rows = wrap_spans(&spans, 3);
        // Every row must contain only bold or italic content.
        for row in &rows {
            for ws in &row.spans {
                assert!(
                    ws.style == bold() || ws.style == italic(),
                    "unexpected style on row: {:?}",
                    ws.style
                );
            }
        }
    }

    // ── case 8: wide CJK characters ──────────────────────────────────────────

    #[test]
    fn wide_cjk_no_row_exceeds_width() {
        let widths = [20u16, 40, 60, 80, 120, 200];
        at_widths(&widths, |w| {
            // Each CJK char is 2 columns wide.
            let s: String = "你好世界".repeat(20);
            wrap_spans(&[raw(&s)], w)
        });
    }

    // ── case 8b: a character wider than the whole budget ─────────────────────

    #[test]
    fn a_character_wider_than_the_width_never_overflows() {
        // A CJK character is two columns wide, so at a width of 1 there is no
        // row it can be placed on — not even a row of its own. Every emitted
        // row must still respect the budget, and there must be no spurious
        // empty row ahead of the content.
        let rows = wrap_spans(&[raw("你好世界")], 1);
        for (i, row) in rows.iter().enumerate() {
            assert!(
                row.width <= 1,
                "row {i} is {} columns wide at a width of 1",
                row.width
            );
        }
        assert_eq!(
            rows.len(),
            1,
            "nothing can be placed at width 1, so the result is a single empty row"
        );
        assert!(rows[0].spans.is_empty());

        // Narrower characters around the wide one are still placed.
        let rows = wrap_spans(&[raw("a你b")], 1);
        let placed: String = rows
            .iter()
            .flat_map(|r| r.spans.iter().map(|s| s.content.as_str()))
            .collect();
        assert_eq!(placed, "ab", "characters that do fit must still be emitted");
        for row in &rows {
            assert!(row.width <= 1);
        }
    }

    // ── case 9: combining marks stay glued to their base char ────────────────

    #[test]
    fn combining_marks_stay_glued() {
        // 'e' + U+0301 COMBINING ACUTE ACCENT = "é" as two code points.
        // The grapheme cluster must not be split across rows.
        let composed = "e\u{0301}"; // decomposed é
        let input: String = composed.repeat(50);
        let rows = wrap_spans(&[raw(&input)], 10);
        for row in &rows {
            let text: String = row.spans.iter().map(|s| s.content.as_str()).collect();
            // A combining char must not appear at position 0 of any row text
            // (that would mean it was separated from its base).
            let first_char = text.chars().next().unwrap_or('x');
            let first_w = UnicodeWidthChar::width(first_char).unwrap_or(1);
            assert!(
                first_w > 0,
                "row must not start with a combining mark: {text:?}"
            );
        }
    }

    // ── case 10: max_width == 0 ──────────────────────────────────────────────

    #[test]
    fn max_width_zero_one_row_per_hard_line_width_zero() {
        // Two hard lines → two output rows, each with width 0.
        let rows = wrap_spans(&[raw("hello\nworld")], 0);
        assert_eq!(rows.len(), 2, "one row per hard line: {rows:?}");
        for row in &rows {
            assert_eq!(row.width, 0);
            assert!(row.spans.is_empty());
        }

        // No newlines → one row.
        let rows = wrap_spans(&[raw("hello")], 0);
        assert_eq!(rows.len(), 1);
    }

    // ── case 11: idempotence (soft-wrap only) ────────────────────────────────

    /// `wrap(flatten(wrap(input, w)), w) == wrap(input, w)` for soft-wrap-only
    /// inputs. Inputs containing hard `'\n'` characters do **not** satisfy this
    /// property because `flatten_soft_wrapped` cannot recover whether a row
    /// boundary was a soft wrap or a hard break — the input here is
    /// deliberately newline-free to keep the property well-defined.
    #[test]
    fn soft_wrap_idempotence() {
        let input = [raw("the quick brown fox jumps over the lazy dog")];
        debug_assert!(
            !input.iter().any(|s| s.content.contains('\n')),
            "soft_wrap_idempotence requires newline-free input",
        );
        for &w in &[20u16, 40, 80] {
            let first = wrap_spans(&input, w);
            let flat = flatten_soft_wrapped(&first);
            let second = wrap_spans(&flat, w);
            assert_eq!(
                first.len(),
                second.len(),
                "width {w}: row count changed after re-wrap (first={}, second={})",
                first.len(),
                second.len()
            );
            for (i, (r1, r2)) in first.iter().zip(second.iter()).enumerate() {
                assert_eq!(
                    r1.width, r2.width,
                    "width {w} row {i}: width changed (first={}, second={})",
                    r1.width, r2.width
                );
            }
        }
    }

    /// Hard `'\n'` characters are **consumed** at row boundaries: they never
    /// appear in any output `WrappedSpan::content`.
    #[test]
    fn hard_newline_consumed_never_appears_in_output() {
        let rows = wrap_spans(&[raw("alpha\nbeta\ngamma")], 80);
        assert_eq!(rows.len(), 3);
        for row in &rows {
            for ws in &row.spans {
                assert!(
                    !ws.content.contains('\n'),
                    "hard newline leaked into output: {ws:?}",
                );
            }
        }
    }

    // ── case 12: measure round-trip ──────────────────────────────────────────

    #[test]
    fn measure_round_trip() {
        let spans = [raw("hello world")];
        let m = measure(&spans);
        let rows = wrap_spans(&spans, u16::MAX);
        assert_eq!(
            rows.len(),
            1,
            "single-line input at max width should produce exactly one row"
        );
        assert_eq!(
            m, rows[0].width,
            "measure() must equal wrap_spans(..., u16::MAX)[0].width"
        );
    }

    // ── width-sweep invariant ────────────────────────────────────────────────

    #[test]
    fn width_sweep_long_word() {
        at_widths(&[20, 40, 60, 80, 120, 200], |w| {
            let s = "superlongwordwithnobreaks".repeat(8);
            wrap_spans(&[raw(&s)], w)
        });
    }

    // ── to_line ──────────────────────────────────────────────────────────────

    #[test]
    fn to_line_round_trips_content_and_style() {
        let rows = wrap_spans(&[styled("hello world", bold())], 5);
        assert_eq!(rows.len(), 2);
        let line = rows[0].to_line();
        assert_eq!(line.text(), "hello");
        assert!(line.spans.iter().all(|s| s.style == bold()));
    }
}
