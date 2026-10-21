//! Renderer for Mermaid sequence diagrams.
//!
//! Produces a Unicode box-drawing text representation of a
//! [`SequenceDiagram`].  The layout follows termaid's conventions:
//!
//! - Participant boxes are drawn across the top in declaration order.
//! - A vertical dashed lifeline `┆` runs below each box.
//! - Each message occupies an arrow row; its label appears on the rows above.
//! - Labels that are too wide for the budget wrap rather than being clipped, so
//!   a label can be several rows tall and the layout grows to hold it.
//! - Solid arrows use `─` and `▸`/`◂`; dashed arrows use `┄` and `▸`/`◂`.
//!
//! `render` takes an optional column budget. Given one, it wraps participant
//! and message labels until the layout fits, stepping the wrap target down a
//! bounded number of times; if nothing fits it returns the narrowest layout it
//! reached rather than clipping anything. Given `None` it lays the diagram out
//! at its natural width.
//!
//! # Examples
//!
//! ```
//! use mermaid_text::parser::sequence::parse;
//! use mermaid_text::render::sequence::render;
//!
//! let diag = parse("sequenceDiagram\nA->>B: hello").unwrap();
//! let out = render(&diag, None);
//! assert!(out.contains('A'));
//! assert!(out.contains('B'));
//! assert!(out.contains('┆'));
//! ```

use std::{borrow::Cow, collections::BTreeMap};

use unicode_width::UnicodeWidthStr;

use crate::render::box_table::{grid_to_string_with_marks, put_cell, put_str_with_marks};
use crate::sequence::{
    AutonumberState, Block, BlockKind, MessageStyle, NoteAnchor, ParticipantGroup, SequenceDiagram,
};
use crate::types::Rgb;

// ---------------------------------------------------------------------------
// Layout constants (mirroring termaid's naming conventions)
// ---------------------------------------------------------------------------

/// Horizontal padding cells added inside each participant box on each side.
const BOX_PAD: usize = 2;

/// Height of a participant box in rows: top border, the label's rows, bottom
/// border. Three rows for a one-line label, which is the unwrapped case.
///
/// The height is a function rather than a constant because a label too wide for
/// the budget is wrapped rather than clipped, and a wrapped label needs rows to
/// live in. Every box on a diagram shares one height — see `box_h` in `render`
/// — so the header and footer still read as a bracket.
fn box_height(label_lines: usize) -> usize {
    label_lines.max(1) + 2
}

/// Minimum gap between two adjacent participant *centre* columns.
/// Minimum clearance (in cells) between the inner edges of two adjacent
/// participant boxes. Baseline when no message label crosses the gap;
/// labels widen it further via [`LABEL_PADDING`].
const MIN_GAP: usize = 2;

/// Cells added to a message label's width when computing how much gap
/// space that label needs. Covers one cell of visual padding at the left
/// of the label and one at the right of the arrow tip.
const LABEL_PADDING: usize = 2;

/// Rows a regular (non-self) message event consumes: its label's rows, then the
/// arrow row. Two rows for a one-line label.
fn message_height(label_lines: usize) -> usize {
    label_lines.max(1) + 1
}

/// Rows a self-message event consumes: its top leg, the label's rows, its
/// bottom leg, then one blank row — matching the spacing a regular message
/// leaves before the next label. Four rows for a one-line label.
fn self_message_height(label_lines: usize) -> usize {
    label_lines.max(1) + 3
}

/// Right-pointing solid arrowhead.
const ARROW_RIGHT: char = '▸';
/// Left-pointing solid arrowhead.
const ARROW_LEFT: char = '◂';

/// Solid horizontal line character.
const H_SOLID: char = '─';
/// Dashed horizontal line character.
const H_DASH: char = '┄';

/// Lifeline character.
const LIFELINE: char = '┆';

// Activation bar — full-block glyph, drawn ACTIVATION_BAR_WIDTH cells
// wide centred on the lifeline so the active span reads as a "filled
// rectangle" matching Mermaid's SVG output rather than a thin heavy
// line. The bar overlays the dashed lifeline `┆` and skips cells
// already holding arrow/junction glyphs from messages.
const ACTIVATION_BAR: char = '█';
const ACTIVATION_BAR_WIDTH: usize = 2;

/// Parsed activations close in LIFO order. Equal message ranges still occupy
/// distinct lanes: the earlier closed span is the inner one.
fn activation_depth(diag: &SequenceDiagram, index: usize) -> usize {
    let act = &diag.activations[index];
    diag.activations
        .iter()
        .enumerate()
        .filter(|&(other_index, other)| {
            other_index != index
                && other.participant == act.participant
                && other.start_message <= act.start_message
                && other.end_message >= act.end_message
                && ((other.start_message, other.end_message)
                    != (act.start_message, act.end_message)
                    || other_index > index)
        })
        .count()
}

fn activation_widths(diag: &SequenceDiagram, depths: &[usize]) -> Vec<usize> {
    let mut widths = vec![0; diag.participants.len()];
    for (index, act) in diag.activations.iter().enumerate() {
        if let Some(pi) = diag.participant_index(&act.participant) {
            widths[pi] =
                widths[pi].max(depths[index] * (ACTIVATION_BAR_WIDTH + 1) + ACTIVATION_BAR_WIDTH);
        }
    }
    widths
}

/// Sparse width changes at message boundaries; endpoint lookup is logarithmic
/// in this participant's activation events rather than scanning every span.
fn active_lane_index(diag: &SequenceDiagram, depths: &[usize]) -> Vec<Vec<(usize, usize)>> {
    let mut events = vec![Vec::new(); diag.participants.len()];
    for (index, act) in diag.activations.iter().enumerate() {
        if act.start_message > act.end_message || act.end_message >= diag.messages.len() {
            continue;
        }
        if let Some(pi) = diag.participant_index(&act.participant) {
            events[pi].push((act.start_message, depths[index], true));
            events[pi].push((act.end_message + 1, depths[index], false));
        }
    }
    events
        .into_iter()
        .map(|mut events| {
            events.sort_unstable();
            let mut active = BTreeMap::<usize, usize>::new();
            let mut changes = Vec::new();
            for (message, depth, opening) in events {
                if opening {
                    *active.entry(depth).or_default() += 1;
                } else if let Some(count) = active.get_mut(&depth) {
                    *count -= 1;
                    if *count == 0 {
                        active.remove(&depth);
                    }
                }
                let width = active.last_key_value().map_or(0, |(&depth, _)| {
                    depth * (ACTIVATION_BAR_WIDTH + 1) + ACTIVATION_BAR_WIDTH
                });
                if changes.last().is_some_and(|&(at, _)| at == message) {
                    changes.pop();
                }
                changes.push((message, width));
            }
            changes
        })
        .collect()
}

fn active_width(changes: &[(usize, usize)], message: usize) -> usize {
    let end = changes.partition_point(|&(at, _)| at <= message);
    end.checked_sub(1).map_or(0, |index| changes[index].1)
}

/// Right edge of the active lanes at a message, or the ordinary lifeline.
fn message_anchor(layout: &ParticipantLayout, width: usize, right: bool) -> usize {
    if width == 0 {
        layout.center
    } else if right {
        layout.center + width
    } else {
        layout.center.saturating_sub(1)
    }
}

/// Compute the exact displayed labels once for both layout and painting.
fn message_labels(diag: &SequenceDiagram) -> Vec<Cow<'_, str>> {
    let mut state = AutonumberState::Off;
    let mut cursor = 0;
    diag.messages
        .iter()
        .enumerate()
        .map(|(index, message)| {
            while cursor < diag.autonumber_changes.len()
                && diag.autonumber_changes[cursor].at_message <= index
            {
                state = diag.autonumber_changes[cursor].state;
                cursor += 1;
            }
            match state {
                AutonumberState::Off => Cow::Borrowed(message.text.as_str()),
                AutonumberState::On { next_value } => {
                    state = AutonumberState::On {
                        next_value: next_value.saturating_add(1),
                    };
                    Cow::Owned(if message.text.is_empty() {
                        format!("[{next_value}]")
                    } else {
                        format!("[{next_value}] {}", message.text)
                    })
                }
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

/// A simple character grid for building up the rendered output.
struct Canvas {
    /// Stored in row-major order: `grid[row][col]`.
    grid: Vec<Vec<char>>,
    combining_marks: std::collections::HashMap<(usize, usize), String>,
    width: usize,
    height: usize,
}

impl Canvas {
    fn new(width: usize, height: usize) -> Self {
        Self {
            grid: vec![vec![' '; width]; height],
            combining_marks: std::collections::HashMap::new(),
            width,
            height,
        }
    }

    /// Write a single character at `(row, col)`, silently clamping to bounds.
    fn put(&mut self, row: usize, col: usize, ch: char) {
        if row < self.height && col < self.width && self.grid[row][col] != '\0' {
            put_cell(&mut self.grid, row, col, ch);
            self.combining_marks.remove(&(row, col));
        }
    }

    /// Write text in terminal columns using the shared continuation/mark rules.
    fn put_str(&mut self, row: usize, col: usize, s: &str) {
        put_str_with_marks(&mut self.grid, &mut self.combining_marks, row, col, s);
    }

    /// Render the grid with trailing-space and trailing-blank-row trimming.
    fn into_string(self) -> String {
        grid_to_string_with_marks(&self.grid, &self.combining_marks)
    }
}

// ---------------------------------------------------------------------------
// Layout computation
// ---------------------------------------------------------------------------

/// Per-participant layout data.
struct ParticipantLayout {
    /// Column of the vertical *centre* of the participant box / lifeline.
    center: usize,
    /// Total width of the participant box (border-to-border).
    box_width: usize,
}

/// Compute column centres and box widths for all participants.
///
/// Column centres are chosen so that:
/// 1. Each box is wide enough to contain its label with `BOX_PAD` on each side.
/// 2. The gap between adjacent centres is at least `MIN_GAP`.
/// 3. The gap is widened further when a message label crossing that gap
///    would not otherwise fit.
fn compute_layout(
    diag: &SequenceDiagram,
    lane_widths: &[usize],
    participant_labels: &[Cow<'_, str>],
    labels: &[Cow<'_, str>],
) -> Vec<ParticipantLayout> {
    let n = diag.participants.len();
    if n == 0 {
        return Vec::new();
    }

    // Minimum box width = widest line of the label + 2 * BOX_PAD + 2 (borders).
    // A wrapped label is measured by its widest line, not its whole text: the
    // box is as wide as it needs to be and no wider, which is what lets a
    // wrapped diagram actually come out narrower.
    let box_widths: Vec<usize> = participant_labels
        .iter()
        .map(|label| {
            let label_w = max_line_width(label);
            // Ensure the box is at least wide enough for its label.
            (label_w + 2 * BOX_PAD + 2).max(8)
        })
        .collect();

    // Per-gap minimum width driven by message labels that cross that gap.
    // gap_mins[i] is the minimum distance between centres of participant i and i+1.
    let mut gap_mins = vec![MIN_GAP; n.saturating_sub(1)];

    for (msg, label) in diag.messages.iter().zip(labels) {
        let Some(si) = diag.participant_index(&msg.from) else {
            continue;
        };
        let Some(ti) = diag.participant_index(&msg.to) else {
            continue;
        };
        if si == ti {
            continue; // self-message; handled separately
        }
        let lo = si.min(ti);
        let hi = si.max(ti);
        let spans = hi - lo;
        // Label needs `label_width + LABEL_PADDING` cells of clearance along
        // its arrow; divide across the spans the arrow crosses. A wrapped
        // label needs only its widest line's worth of clearance, because the
        // rest of it sits on the rows above.
        let label_need = max_line_width(label) + LABEL_PADDING;
        // With active lanes, keep a label in the first gap so an intervening
        // participant's continuous bar cannot overwrite it.
        let per_gap = if diag.activations.is_empty() {
            label_need.div_ceil(spans)
        } else {
            label_need
        };
        for slot in gap_mins.iter_mut().take(hi).skip(lo) {
            *slot = (*slot).max(per_gap);
        }
    }

    // Build centre positions cumulatively from the left.
    //
    // `gap_mins[i]` is the minimum *clearance* between the inner edges of
    // box i and box i+1 (not a centre-to-centre distance) so that wide
    // participant labels don't cause boxes to visually touch. Converting
    // to centre-to-centre: add half the previous box's width and half the
    // current box's width.
    let left_margin = box_widths[0] / 2 + 1;
    let mut layouts = Vec::with_capacity(n);
    let mut prev_center = left_margin;

    for i in 0..n {
        let center = if i == 0 {
            left_margin
        } else {
            prev_center
                + box_widths[i - 1] / 2
                + gap_mins[i - 1]
                + box_widths[i] / 2
                + lane_widths[i - 1]
        };
        layouts.push(ParticipantLayout {
            center,
            box_width: box_widths[i],
        });
        prev_center = center;
    }

    layouts
}

/// Re-wrap each message label to the room it has in `layouts`.
///
/// The first pass wraps every label to one diagram-wide target, which is what
/// sizes the gaps — but the gap a label ends up in is usually decided by some
/// *other* label, or by the boxes either side of it. Wrapping to the target
/// anyway crushes a label that has room for two rows into six, and the diagram
/// gets taller for nothing. This pass gives each label back the room it
/// actually has.
///
/// The room is read off the layout rather than recomputed from the target: the
/// clearance between two adjacent participants is exactly what
/// [`compute_layout`] allocated to the labels spanning it, and a label spanning
/// several gaps is divided across all of them, so the narrowest gap it spans —
/// times the number of gaps — is the bound the next layout has to reproduce.
/// Wrapping to that means the widest line plus `LABEL_PADDING` is at most
/// `narrowest * spans`, so `div_ceil(spans)` lands back inside every gap the
/// label crosses and `gap_mins` comes out unchanged. Widening a label therefore
/// cannot widen the diagram.
///
/// Self-message labels are left exactly as the first pass wrapped them. A
/// self-message's loop is sized from its own label
/// ([`draw_self_message`]'s `loop_w`), so it has no room to fill: wrapping it
/// wider would widen the loop by the same amount.
///
/// `wrapped` is the first pass's output, used for every label this pass leaves
/// alone. The labels it *does* fill are re-wrapped from the diagram's own text,
/// not from `wrapped`: [`wrap_note_text`] keeps existing newlines, so feeding it
/// an already-wrapped label would preserve the breaks this pass exists to undo.
fn fill_message_labels<'a>(
    diag: &'a SequenceDiagram,
    wrapped: &[Cow<'a, str>],
    layouts: &[ParticipantLayout],
    lane_widths: &[usize],
) -> Vec<Cow<'a, str>> {
    // The clearance between participants i and i+1, read back out of the
    // centres. `compute_layout` places a centre as
    // `prev + bw[i]/2 + gap + bw[i+1]/2 + lane[i]`, so this inverts it exactly.
    let clearances: Vec<usize> = (1..layouts.len())
        .map(|i| {
            layouts[i]
                .center
                .saturating_sub(layouts[i - 1].center)
                .saturating_sub(layouts[i - 1].box_width / 2)
                .saturating_sub(layouts[i].box_width / 2)
                .saturating_sub(lane_widths[i - 1])
        })
        .collect();

    message_labels(diag)
        .into_iter()
        .zip(diag.messages.iter())
        .zip(wrapped)
        .map(|((label, msg), wrapped_label)| {
            let (Some(si), Some(ti)) = (
                diag.participant_index(&msg.from),
                diag.participant_index(&msg.to),
            ) else {
                return wrapped_label.clone();
            };
            if si == ti {
                return wrapped_label.clone();
            }
            let (lo, hi) = (si.min(ti), si.max(ti));
            let spans = hi - lo;
            let room = if diag.activations.is_empty() {
                // Divided across the gaps the arrow crosses, so the narrowest of
                // them times `spans` is what every gap has to hold.
                clearances[lo..hi].iter().copied().min().unwrap_or(0) * spans
            } else {
                // With active lanes the label is kept whole in the first gap.
                clearances[lo]
            };
            match room.checked_sub(LABEL_PADDING) {
                Some(width) if width > 0 => Cow::Owned(wrap_note_text(&label, width)),
                _ => wrapped_label.clone(),
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

/// Draw a participant box centered on `cx`, with the top border on `top_row`.
/// The box occupies [`box_height`] rows: the top border, one row per line of
/// `label`, then the bottom border.
///
/// ```text
/// ┌──────────┐
/// │ Steering │
/// │ Service  │
/// └──────────┘
/// ```
///
/// Each label line is centred on its own row, so a wrapped label reads as a
/// centred block rather than a ragged one. `label` must have no more lines than
/// the caller sized the box for — `render` sizes every box from the widest
/// wrapped label on the diagram, and the two must agree or the bottom border
/// lands on a label row.
///
/// Used twice per render: once at `top_row = 0` for the header and once at
/// `top_row = canvas.height - box_height` for the mirrored footer (matches
/// Mermaid's convention of bracketing lifelines).
fn draw_participant_box(
    canvas: &mut Canvas,
    cx: usize,
    box_width: usize,
    label: &str,
    top_row: usize,
) {
    let left = cx.saturating_sub(box_width / 2);
    let right = left + box_width - 1; // inclusive column of right border
    let lines: Vec<&str> = label.lines().collect();
    let lines = if lines.is_empty() { vec![""] } else { lines };
    let bottom_row = top_row + box_height(lines.len()) - 1;

    // Top border
    canvas.put(top_row, left, '┌');
    for c in (left + 1)..right {
        canvas.put(top_row, c, '─');
    }
    canvas.put(top_row, right, '┐');

    // Label rows — each line centred inside the box.
    let inner_w = box_width.saturating_sub(2); // space between borders
    for (i, line) in lines.iter().enumerate() {
        let row = top_row + 1 + i;
        let label_start = left + 1 + (inner_w.saturating_sub(line.width())) / 2;
        canvas.put(row, left, '│');
        canvas.put_str(row, label_start, line);
        canvas.put(row, right, '│');
    }

    // Bottom border
    canvas.put(bottom_row, left, '└');
    for c in (left + 1)..right {
        canvas.put(bottom_row, c, '─');
    }
    canvas.put(bottom_row, right, '┘');
}

/// Draw a multi-line note box on the canvas with rounded corners.
///
/// `left` and `right` are the inclusive column bounds; `text` is the
/// note's content (one logical line per `\n`). Box height is
/// `text.lines().count() + 2` (top border + content rows + bottom
/// border). Rounded corners (`╭ ╮ ╰ ╯`) distinguish notes from
/// participant header boxes (which use square `┌ ┐ └ ┘` corners).
///
/// Lifelines are drawn in an earlier pass; the note's borders
/// naturally overwrite the dashed `┆` glyphs in the columns it
/// occupies, which reads as the note "covering" the lifeline at
/// that point.
fn draw_note_box(canvas: &mut Canvas, left: usize, right: usize, row: usize, text: &str) {
    if right < left {
        return;
    }
    let lines: Vec<&str> = text.lines().collect();
    let height = lines.len() + 2;

    // Top border.
    canvas.put(row, left, '╭');
    for c in (left + 1)..right {
        canvas.put(row, c, '─');
    }
    canvas.put(row, right, '╮');

    // Content rows. Lifelines (`┆`) drawn in an earlier pass may
    // intrude on the interior columns; clear the interior to spaces
    // first so the note reads as a solid box rather than a frame
    // with dashed lines bleeding through.
    let inner_left = left + 2; // 1 cell padding inside the border
    for (i, line) in lines.iter().enumerate() {
        let r = row + 1 + i;
        canvas.put(r, left, '│');
        for c in (left + 1)..right {
            canvas.put(r, c, ' ');
        }
        canvas.put(r, right, '│');
        canvas.put_str(r, inner_left, line);
    }

    // Bottom border.
    let bottom = row + height - 1;
    canvas.put(bottom, left, '╰');
    for c in (left + 1)..right {
        canvas.put(bottom, c, '─');
    }
    canvas.put(bottom, right, '╯');
}

/// Compute the inclusive `(left_col, right_col)` for a note box
/// based on its anchor and the current participant layouts.
///
/// Returns `None` when the anchor names a participant that doesn't
/// exist in the diagram (the parser auto-creates participants
/// referenced by messages, but a note can name a never-mentioned id).
fn note_columns(
    anchor: &NoteAnchor,
    layouts: &[ParticipantLayout],
    diag: &SequenceDiagram,
    text_w: usize,
    lane_widths: &[usize],
) -> Option<(usize, usize)> {
    // Box width = text + 2 cells padding each side + 2 borders.
    let box_w = text_w + 4;
    match anchor {
        NoteAnchor::LeftOf(id) => {
            let i = diag.participant_index(id)?;
            let right = layouts[i].center.saturating_sub(2);
            let left = right.saturating_sub(box_w.saturating_sub(1));
            Some((left, right))
        }
        NoteAnchor::RightOf(id) => {
            let i = diag.participant_index(id)?;
            let left = layouts[i].center + lane_widths[i] + 2;
            Some((left, left + box_w - 1))
        }
        NoteAnchor::Over(id) => {
            let i = diag.participant_index(id)?;
            let center = layouts[i].center;
            let left = center.saturating_sub(box_w / 2);
            Some((left, left + box_w - 1))
        }
        NoteAnchor::OverPair(a, b) => {
            let i = diag.participant_index(a)?;
            let j = diag.participant_index(b)?;
            let (lo, hi) = if i <= j { (i, j) } else { (j, i) };
            let span_left = layouts[lo].center;
            let span_right = layouts[hi].center;
            let span_w = span_right - span_left + 1;
            // Widen the box to span both anchors + padding; if the
            // text is wider than the span, the box extends to fit.
            let needed_w = box_w.max(span_w + 2);
            let centre = (span_left + span_right) / 2;
            let left = centre.saturating_sub(needed_w / 2);
            Some((left, left + needed_w - 1))
        }
    }
}

/// Compute the maximum display width across the lines of `text`.
fn max_line_width(text: &str) -> usize {
    text.lines().map(|l| l.width()).max().unwrap_or(0)
}

/// Word-wrap `text` so that no line exceeds `budget` display cells.
///
/// Each pre-existing `\n` in `text` is an authoritative break (from the user's
/// `<br>` or `<br/>`) and is always preserved exactly — the lines it produces
/// are never re-joined and re-split. Within each such segment, words are packed
/// greedily left-to-right. A word that exceeds `budget` by itself is left on
/// its own line and the canvas-widening pass will handle it.
///
/// Returns the wrapped string. If every line already fits within `budget`,
/// the input is returned unchanged.
fn wrap_note_text(text: &str, budget: usize) -> String {
    if budget == 0 {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    for (seg_idx, segment) in text.split('\n').enumerate() {
        if seg_idx > 0 {
            out.push('\n');
        }
        // If the segment already fits, emit it unchanged.
        if segment.width() <= budget {
            out.push_str(segment);
            continue;
        }
        // Greedy word-wrap within this segment.
        let mut current_w = 0usize;
        let mut first_word = true;
        for word in segment.split_ascii_whitespace() {
            let w = word.width();
            if first_word {
                out.push_str(word);
                current_w = w;
                first_word = false;
            } else if current_w + 1 + w <= budget {
                out.push(' ');
                out.push_str(word);
                current_w += 1 + w;
            } else {
                // Word doesn't fit on current line — start a new one.
                out.push('\n');
                out.push_str(word);
                current_w = w;
            }
        }
        // Segment was non-empty whitespace-only (edge case).
        if first_word {
            out.push_str(segment);
        }
    }
    out
}

/// Compute the text-width budget for a note given its anchor.
///
/// Budget = available display columns for note content (excluding the 2-cell
/// border and 2-cell padding on each side, i.e., box_width - 4).
///
/// Policy:
/// - `LeftOf(X)`: everything to the left of the anchor's lifeline, minus the
///   2-cell gap between box right edge and the lifeline.
/// - `RightOf(X)`: everything to the right of the anchor, clipped to a
///   comfortable 30 cells so the box doesn't run off-screen on typical terms.
/// - `Over(X)`: 40 cells (Mermaid-ish default for single-participant notes).
/// - `OverPair(X, Y)`: the span between the two centres, minus box padding.
fn note_budget(
    anchor: &NoteAnchor,
    layouts: &[ParticipantLayout],
    diag: &SequenceDiagram,
) -> usize {
    const RIGHT_OF_BUDGET: usize = 30;
    const OVER_SINGLE_BUDGET: usize = 40;
    const BOX_OVERHEAD: usize = 4; // 2 borders + 2 padding cells on each side = 4 per side? No: overhead is border(1)+pad(1) on each side = 4 total

    match anchor {
        NoteAnchor::LeftOf(id) => {
            let Some(i) = diag.participant_index(id) else {
                return OVER_SINGLE_BUDGET;
            };
            let right_edge = layouts[i].center.saturating_sub(2);
            right_edge.saturating_sub(BOX_OVERHEAD)
        }
        NoteAnchor::RightOf(_) => RIGHT_OF_BUDGET,
        NoteAnchor::Over(_) => OVER_SINGLE_BUDGET,
        NoteAnchor::OverPair(a, b) => {
            let Some(i) = diag.participant_index(a) else {
                return OVER_SINGLE_BUDGET;
            };
            let Some(j) = diag.participant_index(b) else {
                return OVER_SINGLE_BUDGET;
            };
            let (lo, hi) = if i <= j { (i, j) } else { (j, i) };
            let span_w = layouts[hi].center.saturating_sub(layouts[lo].center) + 1;
            span_w.saturating_sub(BOX_OVERHEAD).max(OVER_SINGLE_BUDGET)
        }
    }
}

/// Draw the lifeline `┆` column from row `start` to row `end` (inclusive).
fn draw_lifeline(canvas: &mut Canvas, cx: usize, start: usize, end: usize) {
    for r in start..=end {
        // Only overwrite spaces — don't clobber arrow characters.
        if canvas.grid[r][cx] == ' ' {
            canvas.put(r, cx, LIFELINE);
        }
    }
}

/// Draw a horizontal message arrow between two column centres on `row`.
/// The label is placed on `row - 1` (above the arrow).
fn draw_message(
    canvas: &mut Canvas,
    src_cx: usize,
    tgt_cx: usize,
    row: usize,
    text: &str,
    style: MessageStyle,
) {
    let going_right = tgt_cx > src_cx;
    let left = src_cx.min(tgt_cx);
    let right = src_cx.max(tgt_cx);
    let h_char = if style.is_dashed() { H_DASH } else { H_SOLID };

    // Draw horizontal line between the two lifeline columns (exclusive of
    // the endpoint columns themselves, which are either arrowheads or line
    // characters).
    for c in (left + 1)..right {
        canvas.put(row, c, h_char);
    }

    if style.has_arrow() {
        if going_right {
            canvas.put(row, left, h_char); // source side: extend line
            canvas.put(row, right, ARROW_RIGHT);
        } else {
            canvas.put(row, left, ARROW_LEFT);
            canvas.put(row, right, h_char);
        }
    } else {
        // No arrowhead — line extends to both endpoints.
        canvas.put(row, left, h_char);
        canvas.put(row, right, h_char);
    }

    // Label above the arrow (termaid convention).
    //
    // A wrapped label stacks upwards from the arrow: its last line sits
    // directly on `row - 1` and earlier lines above that, so the label always
    // ends next to the arrow it names. The caller advances `row` by
    // [`message_height`] for this label's line count, which is what reserves
    // the rows this draws into.
    if !text.is_empty() && row > 0 {
        // Place label starting 2 columns right of the leftmost column so it
        // sits clearly over the arrow shaft.
        let label_col = left + 2;
        let lines: Vec<&str> = text.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            let label_row = row - (lines.len() - i);
            canvas.put_str(label_row, label_col, line);
        }
    }
}

/// Draw a self-message U-shape loop to the right of the lifeline column.
///
/// Layout for a one-line label, occupying rows `row`, `row+1`, `row+2`:
///
/// ```text
/// ├──────┐
/// │ label│   <- right wall `│` flanks the label so its left is non-space
/// ├◂─────┘
/// ```
///
/// A wrapped label widens the U into as many rows as it has lines: the top leg
/// stays at `row`, the label occupies `row+1` onwards, and the bottom leg sits
/// on the last of them. The caller advances `row` by [`self_message_height`]
/// for this label's line count.
///
/// The right vertical bar makes the label's left neighbour a `│`, satisfying
/// the requirement that the label not float in blank space.
fn draw_self_message(canvas: &mut Canvas, cx: usize, row: usize, text: &str, style: MessageStyle) {
    let h_char = if style.is_dashed() { H_DASH } else { H_SOLID };
    let lines: Vec<&str> = text.lines().collect();
    let lines = if lines.is_empty() { vec![""] } else { lines };
    // Width of the horizontal legs: wide enough for the widest line of the
    // label plus 2 cells of padding (one between the lifeline junction and the
    // label, one between the label and the right corner).
    let loop_w = max_line_width(text).max(4) + 3;
    let right = cx + loop_w;
    let bottom_row = row + self_message_height(lines.len()) - 2;

    // Top leg: `├──────┐`.
    canvas.put(row, cx, '├');
    for c in (cx + 1)..right {
        canvas.put(row, c, h_char);
    }
    canvas.put(row, right, '┐');

    // Label rows: right wall with the label inside the U. `│` at the right
    // edge; each line starts one cell after the lifeline junction.
    for (i, line) in lines.iter().enumerate() {
        let label_row = row + 1 + i;
        canvas.put(label_row, right, '│');
        if !line.is_empty() {
            canvas.put_str(label_row, cx + 1, line);
        }
    }

    // Bottom leg: `├◂─────┘`.
    canvas.put(bottom_row, cx, '├');
    if style.has_arrow() {
        canvas.put(bottom_row, cx + 1, ARROW_LEFT);
    } else {
        canvas.put(bottom_row, cx + 1, h_char);
    }
    for c in (cx + 2)..right {
        canvas.put(bottom_row, c, h_char);
    }
    canvas.put(bottom_row, right, '┘');
}

/// Draw a participant group frame: a top-border line at `top_row` and a
/// bottom-border line at `bottom_row` spanning the group's member columns.
///
/// Uses `┌─[Label]──┐` / `└──────────┘` corners (square, distinct from block
/// frames which use double-line `╔╗╚╝` and notes which use rounded `╭╮╰╯`).
/// The label is embedded in the top-border 2 cells from the left corner.
fn draw_participant_group_frame(
    canvas: &mut Canvas,
    grp: &ParticipantGroup,
    layouts: &[ParticipantLayout],
    top_row: usize,
    bottom_row: usize,
) {
    if grp.members.is_empty() {
        return;
    }
    // Compute the column range spanning all member boxes.
    let lo_idx = *grp.members.iter().min().expect("members non-empty");
    let hi_idx = *grp.members.iter().max().expect("members non-empty");
    if lo_idx >= layouts.len() || hi_idx >= layouts.len() {
        return;
    }
    let left = layouts[lo_idx]
        .center
        .saturating_sub(layouts[lo_idx].box_width / 2 + 1);
    let right = layouts[hi_idx].center + layouts[hi_idx].box_width / 2 + 1;
    if right <= left {
        return;
    }

    // Top border: ┌─[Label]──┐
    canvas.put(top_row, left, '┌');
    for c in (left + 1)..right {
        canvas.put(top_row, c, '─');
    }
    canvas.put(top_row, right, '┐');
    // Embed the label tag starting 2 cells from the left corner.
    if !grp.label.is_empty() {
        let tag = format!("[{}]", grp.label);
        canvas.put_str(top_row, left + 2, &tag);
    }

    // Bottom border: └──────────┘
    if bottom_row != top_row {
        canvas.put(bottom_row, left, '└');
        for c in (left + 1)..right {
            canvas.put(bottom_row, c, '─');
        }
        canvas.put(bottom_row, right, '┘');
    }
}

// ---------------------------------------------------------------------------
// Public render entry point
// ---------------------------------------------------------------------------

/// Render a [`SequenceDiagram`] to a Unicode string.
///
/// Returns an empty string if the diagram has no participants.
///
/// `max_width` is a column budget. With `None`, or with a budget the natural
/// layout already meets, the diagram is laid out at its natural width and
/// nothing about it changes. With a budget it does not meet, the diagram is
/// re-laid out with its participant and message labels wrapped — which narrows
/// the boxes and the gaps between them, since a sequence diagram's width is
/// nothing but its labels — and among the layouts that fit, the shortest one is
/// returned.
///
/// Shortest, not narrowest: the budget is a ceiling, so once a layout fits,
/// narrowing it further buys the reader nothing and every extra row costs a
/// scroll. Ties in row count go to the narrower layout — free at the same
/// height, and it is what the caller sizes a popup from — and the target breaks
/// any tie left, so repeated renders agree.
///
/// The result may still exceed the budget: there is a floor below which
/// wrapping cannot go, because every participant keeps a box and every box
/// keeps a border. The caller decides what to do about that; this function's
/// job is to get as close as it can without dropping anything, so with no
/// fitting layout it emits the narrowest one it found.
///
/// # Examples
///
/// ```
/// use mermaid_text::parser::sequence::parse;
/// use mermaid_text::render::sequence::render;
///
/// let diag = parse("sequenceDiagram\nA->>B: hello\nB-->>A: world").unwrap();
/// let out = render(&diag, None);
/// assert!(out.contains("hello"));
/// assert!(out.contains("world"));
/// assert!(out.contains('┆'));
/// ```
pub fn render(diag: &SequenceDiagram, max_width: Option<usize>) -> String {
    let natural = render_wrapped(diag, None);
    let Some(budget) = max_width else {
        return natural;
    };
    if max_line_width(&natural) <= budget {
        return natural;
    }

    // The natural layout is too wide, so wrap the labels and try again. The
    // top of the range is the proportional estimate the flowchart pipeline
    // uses — scaling the widest label by how far over budget the diagram is —
    // and the bottom is the floor: a label of one column still needs a box
    // around it.
    let widest_label = diag
        .participants
        .iter()
        .map(|p| p.label.width())
        .chain(message_labels(diag).iter().map(|l| l.width()))
        .max()
        .unwrap_or(0);
    if widest_label == 0 {
        return natural;
    }

    const MIN_LABEL: usize = 6;
    let actual = max_line_width(&natural);
    let estimate = ((widest_label * budget) / actual).max(MIN_LABEL);

    // Layout width is not monotone in the target: a different wrap point
    // changes box widths, so a smaller target can produce a wider diagram, and
    // nothing here can binary-search the shortest fitting layout. Every target
    // in the range is therefore rendered and measured.
    let domain = estimate - MIN_LABEL + 1;
    let stride = domain.div_ceil(MAX_PROBES).max(1);

    // Best fitting layout: fewest rows, then narrowest, then largest target.
    // Rows come first because they are what the reader scrolls; width breaks
    // the tie because at the same height the smaller diagram is free — and the
    // wire reports this width, which is what a popup sizes itself to. The
    // target is the last tie-break, only so that two renders always agree.
    let mut best_fit: Option<(usize, usize, usize, String)> = None; // (rows, width, target, text)

    // Narrowest layout seen, for the case where nothing fits at all. A wrapping
    // pass can make a diagram wider rather than narrower — a box is sized by
    // its widest line, and splitting a label can leave a long word alone on a
    // row — so this is a comparison, not an assumption.
    let mut narrowest = natural;
    let mut narrowest_w = actual;

    let mut target = estimate;
    loop {
        let candidate = render_wrapped(diag, Some(target));
        let candidate_width = max_line_width(&candidate);
        if candidate_width <= budget {
            let rows = candidate.lines().count();
            let better = match &best_fit {
                None => true,
                Some((best_rows, best_width, best_target, _)) => {
                    rows < *best_rows
                        || (rows == *best_rows && candidate_width < *best_width)
                        || (rows == *best_rows
                            && candidate_width == *best_width
                            && target > *best_target)
                }
            };
            if better {
                best_fit = Some((rows, candidate_width, target, candidate));
            }
        } else if candidate_width < narrowest_w {
            narrowest = candidate;
            narrowest_w = candidate_width;
        }
        if target == MIN_LABEL {
            break;
        }
        // Both ends of the range are always probed: the stride may skip
        // targets in between, but never the estimate or the floor.
        target = target.saturating_sub(stride).max(MIN_LABEL);
    }

    match best_fit {
        Some((_, _, _, text)) => text,
        None => narrowest,
    }
}

/// How many wrapping targets [`render`] may try in one call.
///
/// The scan runs over `MIN_LABEL..=estimate`, and the estimate is at most the
/// widest label's width, so this only binds for a label wider than roughly 260
/// columns. When it binds, the scan is strided — still probing both ends, and
/// still returning a layout that fits, just not provably the shortest one.
const MAX_PROBES: usize = 256;

/// Lay the diagram out, optionally wrapping every label to `wrap` columns.
///
/// `None` is the natural layout: labels are drawn exactly as written.
fn render_wrapped(diag: &SequenceDiagram, wrap: Option<usize>) -> String {
    let n = diag.participants.len();
    if n == 0 {
        return String::new();
    }

    // Nesting depth is invariant across messages; compute it once instead of
    // repeating the containment scan for every endpoint.
    let depths: Vec<_> = (0..diag.activations.len())
        .map(|i| activation_depth(diag, i))
        .collect();
    let lane_widths = activation_widths(diag, &depths);
    let active_lanes = active_lane_index(diag, &depths);

    // Wrapping happens once, here, and everything downstream reads the result:
    // box widths, gap minimums, heights and the drawing passes all have to
    // agree on the label or a wrapped diagram is drawn into rows sized for an
    // unwrapped one.
    let participant_labels: Vec<Cow<'_, str>> = diag
        .participants
        .iter()
        .map(|p| match wrap {
            Some(budget) => Cow::Owned(wrap_note_text(&p.label, budget)),
            None => Cow::Borrowed(p.label.as_str()),
        })
        .collect();
    let labels: Vec<Cow<'_, str>> = message_labels(diag)
        .into_iter()
        .map(|label| match wrap {
            Some(budget) => Cow::Owned(wrap_note_text(&label, budget)),
            None => label,
        })
        .collect();
    let mut layouts = compute_layout(diag, &lane_widths, &participant_labels, &labels);
    // A label's room is only knowable once the gaps exist, so filling them is a
    // second pass over the same labels rather than part of the first. It cannot
    // widen the layout — see `fill_message_labels` — and re-laying out is what
    // makes that a computed fact rather than a claim.
    let labels = match wrap {
        Some(_) => {
            let filled = fill_message_labels(diag, &labels, &layouts, &lane_widths);
            layouts = compute_layout(diag, &lane_widths, &participant_labels, &filled);
            filled
        }
        None => labels,
    };

    // Every participant box shares one height, taken from the tallest wrapped
    // label, so the header and footer still line up as a bracket.
    let box_h = box_height(
        participant_labels
            .iter()
            .map(|l| l.lines().count())
            .max()
            .unwrap_or(1),
    );

    // Determine canvas dimensions.
    // Header: `box_h` rows for the participant boxes.
    // Body: one slot per message, sized by that message's own label.
    // We need an extra leading row per message for the label above the arrow,
    // so the body starts at row `box_h + 1` (the +1 is the label row for the
    // first message).
    let num_messages = diag.messages.len();

    // The rows each message's label needs, computed once here because three
    // places depend on it: the canvas height, the drawing loop's row cursor,
    // and the label drawing itself. They must agree exactly.
    let message_lines: Vec<usize> = labels.iter().map(|l| l.lines().count().max(1)).collect();
    let message_rows: Vec<usize> = diag
        .messages
        .iter()
        .zip(&message_lines)
        .map(|(msg, &lines)| {
            if msg.from == msg.to {
                self_message_height(lines)
            } else {
                message_height(lines)
            }
        })
        .collect();

    // Total body rows. A regular message's label sits *above* its arrow, so
    // the row cursor has to reserve the next label's rows before moving on —
    // which means every message but the last pays for the label that follows
    // it, not just for its own. `message_rows` already counts each message's
    // label rows once, so the reservation adds them a second time for all but
    // the last; the trailing `1` is the blank row under the final arrow.
    //
    // For one-line labels this collapses to `1 + sum(message_rows)`, which is
    // what the layout used before labels could wrap.
    let body_rows = if num_messages == 0 {
        2 // just lifeline + blank
    } else {
        let reserved: usize = message_lines.iter().take(num_messages - 1).sum();
        1 + message_rows.iter().sum::<usize>() + reserved - (num_messages - 1)
    };

    // Pre-compute wrapped note text for every note. Two-pass approach:
    //   Pass 1 (here): wrap each note's text to its anchor budget, record the
    //           required canvas width for unbreakable words that exceed the
    //           budget, and compute the wrapped line count for height budgeting.
    //   Pass 2 (draw loop): use the wrapped texts when calling draw_note_box.
    let note_wrapped: Vec<String> = diag
        .notes
        .iter()
        .map(|note| {
            let budget = note_budget(&note.anchor, &layouts, diag);
            wrap_note_text(&note.text, budget)
        })
        .collect();

    // Notes consume their own rows in the message stream. Sum them
    // into the height budget so `Canvas::new` allocates enough space.
    // Use the wrapped text line count so the canvas is tall enough.
    let note_rows: usize = note_wrapped
        .iter()
        .map(|t| t.lines().count().max(1) + 3)
        .sum();

    // Block frames add 2 rows per border and per branch divider (1 for
    // the glyph itself + 1 spacer below) so adjacent message labels
    // don't land on the same row as a border. Total per block:
    //   2 (top) + 2 (bottom) + 2 * (extra branches).
    //
    // A border sits directly above the label of the message that starts at its
    // boundary, and a wrapped label is several rows deep. The one spacer row
    // covers a single-line label; every further row has to be reserved as well,
    // or the label's upper rows land on the border. That reservation belongs to
    // the *boundary*, not to the block: several borders can meet there and they
    // share one label, so it is summed once per boundary below.
    let block_rows: usize = diag
        .blocks
        .iter()
        .map(|b| 4 + 2 * b.branches.len().saturating_sub(1))
        .sum::<usize>()
        + {
            let mut boundaries = vec![false; num_messages + 1];
            for b in &diag.blocks {
                if b.start_message < num_messages {
                    boundaries[b.start_message] = true;
                }
                if b.end_message + 1 < num_messages {
                    boundaries[b.end_message + 1] = true;
                }
                for branch in b.branches.iter().skip(1) {
                    if branch.start_message < num_messages {
                        boundaries[branch.start_message] = true;
                    }
                }
            }
            boundaries
                .iter()
                .enumerate()
                .filter(|(_, placed)| **placed)
                .map(|(pos, _)| message_lines[pos].saturating_sub(1))
                .sum::<usize>()
        };

    // Mirror the header participant boxes at the bottom of the canvas
    // (Mermaid convention — lifelines are bracketed top *and* bottom).
    // Add another `BOX_HEIGHT` rows for the footer.
    // When participant groups exist, add 1 row above the header boxes for group
    // top-borders and 1 row below the footer boxes for group bottom-borders.
    let group_frame_rows: usize = if diag.participant_groups.is_empty() {
        0
    } else {
        1
    };
    let height = group_frame_rows
        + box_h
        + body_rows
        + note_rows
        + block_rows
        + box_h
        + group_frame_rows;

    // Canvas width: rightmost participant box right edge + 1 margin.
    let last = &layouts[n - 1];
    // For self-messages on the last participant, add extra width.
    let self_msg_extra = diag
        .messages
        .iter()
        .zip(&labels)
        .filter(|(m, _)| {
            diag.participant_index(&m.from) == diag.participant_index(&m.to)
                && diag.participant_index(&m.from) == Some(n - 1)
        })
        .map(|(_, label)| max_line_width(label) + 6)
        .max()
        .unwrap_or(0);
    let participant_width =
        last.center + last.box_width / 2 + 2 + self_msg_extra + lane_widths[n - 1];

    // Widen the canvas when a note's wrapped text + box overhead would exceed
    // the participant span. This handles unbreakable words (a word wider than
    // the wrapping budget) that couldn't be split by `wrap_note_text`.
    let note_required_width: usize = diag
        .notes
        .iter()
        .zip(note_wrapped.iter())
        .filter_map(|(note, wrapped)| {
            let text_w = max_line_width(wrapped);
            // box_w = text_w + 4 (border + padding on each side)
            let (_l, r) = note_columns(&note.anchor, &layouts, diag, text_w, &lane_widths)?;
            // right edge of the note box + 1 margin
            Some(r + 2)
        })
        .max()
        .unwrap_or(0);

    let width = participant_width.max(note_required_width);

    let mut canvas = Canvas::new(width, height);

    // 1. Draw participant boxes — header (top) and footer (bottom)
    //    mirror, matching Mermaid's bracketed-lifeline convention.
    //    When participant groups exist, boxes are shifted down by group_frame_rows
    //    so there is room for the group top-border row above them.
    let header_top = group_frame_rows;
    let footer_top = height - box_h - group_frame_rows;
    for (i, label) in participant_labels.iter().enumerate() {
        let cx = layouts[i].center;
        let w = layouts[i].box_width;
        draw_participant_box(&mut canvas, cx, w, label, header_top);
        draw_participant_box(&mut canvas, cx, w, label, footer_top);
    }

    // 1a. Draw participant group frames above the header boxes and below the
    //     footer boxes. Each group gets a top-border row at `header_top - 1`
    //     (i.e. row 0 when group_frame_rows == 1) and a bottom-border row at
    //     `footer_top + box_h` (the row right after the footer boxes).
    if group_frame_rows > 0 {
        let group_top_row = 0usize;
        let group_bottom_row = footer_top + box_h;
        for grp in &diag.participant_groups {
            draw_participant_group_frame(
                &mut canvas,
                grp,
                &layouts,
                group_top_row,
                group_bottom_row,
            );
        }
    }

    // 2. Draw lifelines between the header and footer boxes — they
    //    must terminate one row above the footer's top border so the
    //    box outline reads as a clean bracket (lifeline glyphs would
    //    otherwise punch through the `┌────┐`).
    let lifeline_start = header_top + box_h; // row right below the header
    let lifeline_end = footer_top.saturating_sub(1);
    for layout in &layouts {
        draw_lifeline(&mut canvas, layout.center, lifeline_start, lifeline_end);
    }

    // 3. Draw messages.
    //
    // `arrow_row` is the row the *next* message's arrow lands on. A regular
    // message's label occupies the rows immediately above it, so the cursor
    // starts far enough down to clear the first label and each advance pays
    // for the following label rather than the current one. For one-line labels
    // both rules reduce to the old fixed `+1` and `+2`, so a diagram that
    // never wraps lays out exactly as it did before.
    let mut arrow_row =
        header_top + box_h + message_lines.first().copied().unwrap_or(1);

    // Captured arrow row for each message, indexed by message position.
    // Used by the activation-bar overlay pass to translate
    // `Activation::start_message` / `end_message` (message indices) into
    // canvas rows. For self-messages we store the top-leg row so the bar
    // naturally covers both legs.
    let mut message_arrow_rows = vec![None; num_messages];

    // Block frame events to insert at each message-index boundary. At
    // boundary `B`:
    //   - bottom borders of any block ending at message `B - 1`
    //   - top borders of any block starting at message `B`
    //   - dividers for any branch (other than the first) starting at `B`
    // These advance `arrow_row` and capture each event's row so the
    // post-loop overlay pass knows where to draw frames.
    let num_blocks = diag.blocks.len();
    let mut block_top_rows: Vec<usize> = vec![0; num_blocks];
    let mut block_bottom_rows: Vec<usize> = vec![0; num_blocks];
    let mut branch_divider_rows: Vec<Vec<usize>> = diag
        .blocks
        .iter()
        .map(|b| vec![0usize; b.branches.len()])
        .collect();

    // Helper closure: process all block events at message-index `pos`,
    // advancing `arrow_row` by 2 per event (1 for the border/divider
    // glyph row + 1 spacer below it so adjacent message labels don't
    // collide). The border row is the *first* of the two; the spacer
    // is implicitly the second. Inner blocks close before outer blocks
    // at the same position, and outer blocks open before inner blocks.
    // After the events at `pos`, the remaining rows of that message's label
    // are reserved — see the `placed` tail below and the height budget at
    // `block_rows`.
    let apply_block_events = |arrow_row: &mut usize,
                              pos: usize,
                              top_rows: &mut [usize],
                              bottom_rows: &mut [usize],
                              dividers: &mut [Vec<usize>]| {
        let mut placed = false;
        // Bottom borders first (innermost first = forward order in
        // diag.blocks since LIFO close order means innermost has
        // lower idx).
        for (i, b) in diag.blocks.iter().enumerate() {
            if pos > 0 && b.end_message + 1 == pos {
                bottom_rows[i] = *arrow_row;
                *arrow_row += 2;
                placed = true;
            }
        }
        // Top borders next, outermost first (outer block has higher
        // idx in diag.blocks because it closed later — iterate REV).
        for (i, b) in diag.blocks.iter().enumerate().rev() {
            if b.start_message == pos {
                top_rows[i] = *arrow_row;
                *arrow_row += 2;
                placed = true;
            }
        }
        // Branch dividers (continuation rows). Order doesn't matter
        // visually since each belongs to a different block.
        for (i, b) in diag.blocks.iter().enumerate() {
            for (j, branch) in b.branches.iter().enumerate().skip(1) {
                if branch.start_message == pos {
                    dividers[i][j] = *arrow_row;
                    *arrow_row += 2;
                    placed = true;
                }
            }
        }
        // Whatever was drawn here sits above the label of the message at
        // `pos`, and only the first of that label's rows was reserved above.
        // Reserve the rest, or the upper rows of a wrapped label land on the
        // border. Once per boundary: several borders can share one label.
        if placed && pos < num_messages {
            *arrow_row += message_lines[pos].saturating_sub(1);
        }
    };

    // Helper closure: render any notes whose `after_message` matches
    // `at`, advancing `arrow_row` by each note's height. Uses the
    // pre-computed wrapped text so drawing and height accounting agree.
    let mut note_placements = Vec::new();
    let mut render_notes_at = |canvas: &mut Canvas, arrow_row: &mut usize, at: usize| {
        for (note, wrapped) in diag
            .notes
            .iter()
            .zip(note_wrapped.iter())
            .filter(|(n, _)| n.after_message == at)
        {
            let text_w = max_line_width(wrapped);
            if let Some((l, r)) = note_columns(&note.anchor, &layouts, diag, text_w, &lane_widths) {
                note_placements.push((l, r, *arrow_row, wrapped.as_str()));
                draw_note_box(canvas, l, r, *arrow_row, wrapped);
                *arrow_row += wrapped.lines().count().max(1) + 3;
            }
        }
    };

    // Notes positioned BEFORE any message (after_message == 0) land
    // at the top of the body, before the first message label.
    render_notes_at(&mut canvas, &mut arrow_row, 0);

    // Block events at position 0 (any block opening before the first
    // message) land here, before the first message's label row.
    apply_block_events(
        &mut arrow_row,
        0,
        &mut block_top_rows,
        &mut block_bottom_rows,
        &mut branch_divider_rows,
    );

    for (msg_idx, msg) in diag.messages.iter().enumerate() {
        // Block events for this message-index boundary (skip msg_idx == 0
        // because we already applied position 0 events above).
        if msg_idx > 0 {
            apply_block_events(
                &mut arrow_row,
                msg_idx,
                &mut block_top_rows,
                &mut block_bottom_rows,
                &mut branch_divider_rows,
            );
        }

        let label = labels[msg_idx].as_ref();

        let Some((si, ti)) = diag
            .participant_index(&msg.from)
            .zip(diag.participant_index(&msg.to))
        else {
            // Public diagrams may contain unknown IDs. Skip their arrow but
            // retain original message indices and following annotation events.
            render_notes_at(&mut canvas, &mut arrow_row, msg_idx + 1);
            continue;
        };

        // Capture the arrow row for this message before advancing.
        message_arrow_rows[msg_idx] = Some(arrow_row);

        // Rows the *following* message needs above its own arrow: its label's
        // rows. The last message has none to reserve, so it keeps the single
        // blank row that has always trailed the body.
        let next_lines = message_lines.get(msg_idx + 1).copied().unwrap_or(1);

        if si == ti {
            let anchor =
                message_anchor(&layouts[si], active_width(&active_lanes[si], msg_idx), true);
            draw_self_message(&mut canvas, anchor, arrow_row, label, msg.style);
            arrow_row += message_rows[msg_idx] - 1 + next_lines;
        } else {
            draw_message(
                &mut canvas,
                message_anchor(
                    &layouts[si],
                    active_width(&active_lanes[si], msg_idx),
                    si < ti,
                ),
                message_anchor(
                    &layouts[ti],
                    active_width(&active_lanes[ti], msg_idx),
                    ti < si,
                ),
                arrow_row,
                label,
                msg.style,
            );
            arrow_row += message_rows[msg_idx] - 1 + next_lines;
        }

        // Render notes positioned AFTER this message (those whose
        // `after_message` index equals this iteration's index + 1
        // — see NoteEvent::after_message docs in src/sequence.rs).
        render_notes_at(&mut canvas, &mut arrow_row, msg_idx + 1);
    }

    // Trailing block-close events: any block whose end_message + 1
    // equals num_messages (i.e., closes after the last message) needs
    // its bottom border drawn here.
    apply_block_events(
        &mut arrow_row,
        num_messages,
        &mut block_top_rows,
        &mut block_bottom_rows,
        &mut branch_divider_rows,
    );

    // 4. Draw continuous activation lanes. Message endpoints and labels
    // were laid out outside these lanes, including nested and self calls.
    for (index, act) in diag.activations.iter().enumerate() {
        let Some(pi) = diag.participant_index(&act.participant) else {
            continue;
        };
        let Some(start) = message_arrow_rows.get(act.start_message).copied().flatten() else {
            continue;
        };
        let Some(end) = message_arrow_rows.get(act.end_message).copied().flatten() else {
            continue;
        };
        let self_tail = if diag.messages[act.end_message].from == diag.messages[act.end_message].to
        {
            2
        } else {
            0
        };
        let lo = start.saturating_sub(1).max(lifeline_start);
        let hi = (end + self_tail).min(lifeline_end);
        let col = layouts[pi].center + depths[index] * (ACTIVATION_BAR_WIDTH + 1);
        for row in lo..=hi {
            for dx in 0..ACTIVATION_BAR_WIDTH {
                canvas.put(row, col + dx, ACTIVATION_BAR);
            }
        }
    }

    // 5. Overlay block frames. Each block draws a labelled rectangle
    //    spanning the column range of its inner messages, inset by one
    //    cell per nesting level so nested blocks read distinctly. Drawn
    //    last so side rails sit on top of lifelines / activation bars
    //    (still skipping arrow / junction glyphs to read as "behind"
    //    arrows).
    //
    //    Interiors are left blank — see the note on the retired fill pass below.
    //    Rect blocks skip draw_block_frame entirely and are collected into a
    //    separate vec for the fill pass (step 6).
    // (top, bottom, left, right, shade_glyph)
    let mut rect_interiors: Vec<(usize, usize, usize, usize, char)> = Vec::new();
    for (i, b) in diag.blocks.iter().enumerate() {
        // Empty block (no inner messages) — nothing to draw.
        if b.start_message > b.end_message
            || message_arrow_rows
                .get(b.start_message)
                .copied()
                .flatten()
                .is_none()
        {
            continue;
        }
        let Some((natural_left, natural_right)) = block_column_range(b, diag, &layouts) else {
            continue;
        };
        // Depth-based horizontal inset so nested rectangles don't draw
        // on the same columns as their enclosing block(s).
        let depth = block_depth(i, &diag.blocks);
        let max_inset = (natural_right - natural_left) / 4;
        let inset = depth.min(max_inset);
        let left = natural_left.saturating_add(inset);
        let right = natural_right.saturating_sub(inset);
        let top = block_top_rows[i];
        let bottom = block_bottom_rows[i];
        if top == 0 || bottom == 0 || top >= bottom {
            continue;
        }

        // Rect blocks are borderless background fills — no frame drawn.
        if let BlockKind::Rect { rgb, alpha } = b.kind {
            let glyph = rect_shade_glyph(rgb, alpha);
            rect_interiors.push((top, bottom, left, right, glyph));
            continue;
        }

        let kind_label = block_kind_label(b.kind);
        let opener_label = b.branches.first().map(|br| br.label.as_str()).unwrap_or("");
        // Branch dividers (continuations only — first branch has no
        // divider since it shares the top border).
        let branches: Vec<(usize, &str)> = b
            .branches
            .iter()
            .enumerate()
            .skip(1)
            .map(|(j, branch)| (branch_divider_rows[i][j], branch.label.as_str()))
            .filter(|(row, _)| *row != 0)
            .collect();
        draw_block_frame(
            &mut canvas,
            top,
            bottom,
            left,
            right,
            kind_label,
            opener_label,
            &branches,
        );
    }

    // 6. Rect fill — the only fill pass.  A block frame's interior stays blank;
    //    it used to be flooded with `░` (U+2591 LIGHT SHADE), which was retired
    //    because the dithered shade glyphs are disproportionately expensive to
    //    paint: a full-screen repaint of `░▒▓` costs far more than one of `█`
    //    or of ASCII at the same ink coverage, so a diagram whose interior was
    //    all shade made scrolling crawl.  Do not reintroduce them.
    //
    //    A rect block is a borderless background highlight, so its fill is the
    //    whole of it and has to stay.  Replace a cell when it is blank, or when
    //    it already holds a lighter step of the rect palette, so a rect nested
    //    inside another rect keeps the denser of the two.
    for (top, bottom, left, right, glyph) in rect_interiors {
        for r in (top + 1)..bottom {
            for c in (left + 1)..right {
                let cell = canvas.grid[r][c];
                let should_replace = cell == ' '
                    || rect_shade_step(cell)
                        .zip(rect_shade_step(glyph))
                        .is_some_and(|(existing, new)| new > existing);
                if should_replace {
                    canvas.put(r, c, glyph);
                }
            }
        }
    }

    // Opaque notes keep source placement and intentionally cover intersecting
    // lanes/frames; exposed activation cells above and below stay continuous.
    for (left, right, row, text) in note_placements {
        draw_note_box(&mut canvas, left, right, row, text);
    }

    canvas.into_string()
}

/// Nesting depth for `blocks[idx]` — the number of *other* blocks that
/// strictly contain its message range. Used to inset nested rectangles
/// so they read distinctly from their parents.
fn block_depth(idx: usize, blocks: &[Block]) -> usize {
    let me = &blocks[idx];
    blocks
        .iter()
        .enumerate()
        .filter(|(j, b)| {
            *j != idx
                && b.start_message <= me.start_message
                && b.end_message >= me.end_message
                && (b.start_message < me.start_message || b.end_message > me.end_message)
        })
        .count()
}

/// Compute the column range `(left, right)` spanned by all messages
/// inside `block`. Returns `None` if no message in the block resolves
/// to a known participant.
fn block_column_range(
    block: &Block,
    diag: &SequenceDiagram,
    layouts: &[ParticipantLayout],
) -> Option<(usize, usize)> {
    let mut min_idx: Option<usize> = None;
    let mut max_idx: Option<usize> = None;
    for msg in &diag.messages[block.start_message..=block.end_message] {
        for id in [&msg.from, &msg.to] {
            if let Some(p) = diag.participant_index(id) {
                min_idx = Some(min_idx.map_or(p, |m| m.min(p)));
                max_idx = Some(max_idx.map_or(p, |m| m.max(p)));
            }
        }
    }
    let lo = min_idx?;
    let hi = max_idx?;
    let left = layouts[lo]
        .center
        .saturating_sub(layouts[lo].box_width / 2 + 1);
    let right = layouts[hi].center + layouts[hi].box_width / 2 + 1;
    Some((left, right))
}

/// Human-readable label for the block kind, used as a tag in the
/// frame's top-left corner. Mirrors Mermaid's text labels.
fn block_kind_label(kind: BlockKind) -> &'static str {
    match kind {
        BlockKind::Loop => "loop",
        BlockKind::Alt => "alt",
        BlockKind::Opt => "opt",
        BlockKind::Par => "par",
        BlockKind::Critical => "critical",
        BlockKind::Break => "break",
        BlockKind::Rect { .. } => "",
    }
}

/// The three steps of the `rect` fill palette, lightest first.
///
/// ASCII rather than the Unicode shade blocks `░▒▓` (U+2591-93): those are
/// dithered patterns, and a full-screen repaint of them costs far more than one
/// of solid or ASCII glyphs at the same ink coverage — enough to make scrolling
/// a shade-filled diagram crawl.  The steps keep the same light/medium/dark
/// reading, and `.`/`:`/`#` are what `to_ascii` maps the shade blocks to anyway.
const RECT_SHADES: [char; 3] = ['.', ':', '#'];

/// Index of `glyph` in [`RECT_SHADES`], or `None` when it is not a rect fill
/// glyph — which is what tells a rect apart from a lifeline or a label.
fn rect_shade_step(glyph: char) -> Option<usize> {
    RECT_SHADES.iter().position(|&g| g == glyph)
}

/// Choose the fill glyph for a `rect` block using a luminance-keyed 3-step
/// palette.  Effective intensity `I = (255 - luminance) * alpha_norm` where
/// luminance uses the Rec. 601 weights (0.299 R + 0.587 G + 0.114 B).
fn rect_shade_glyph(rgb: Rgb, alpha: Option<u8>) -> char {
    let Rgb(r, g, b) = rgb;
    let luminance = 0.299 * f32::from(r) + 0.587 * f32::from(g) + 0.114 * f32::from(b);
    let alpha_norm = alpha.map_or(1.0_f32, |a| f32::from(a) / 255.0);
    let intensity = (255.0 - luminance) * alpha_norm;
    let step = if intensity < 60.0 {
        0
    } else if intensity < 130.0 {
        1
    } else {
        2
    };
    RECT_SHADES[step]
}

/// Draw a `[label]` tag at the given position, inset 2 cells from the
/// left edge of the block frame so it sits cleanly off the corner.
/// Returns the column past the tag (caller can chain another tag).
/// No-op when `label` is empty — keeps callers free of guard noise.
fn draw_tag(canvas: &mut Canvas, row: usize, anchor_left: usize, label: &str) -> usize {
    if label.is_empty() {
        return anchor_left + 2;
    }
    let col = anchor_left + 2;
    let tag = format!("[{label}]");
    let width = tag.chars().count();
    canvas.put_str(row, col, &tag);
    col + width
}

/// Draw a labelled rectangular frame for a sequence-diagram block.
///
/// Uses the heavy double-line glyphs (`╔╗╚╝═║`) to differentiate from
/// participant boxes (square `┌┐└┘`) and notes (rounded `╭╮╰╯`).
///
/// **Tag layout (matches Mermaid):** the kind name and the opener
/// branch's condition are rendered as **two separate** `[…]` tags on
/// the top border row, e.g. `╔═[alt]══[cache hit]═══════╗`, mirroring
/// Mermaid's badge-plus-condition style. Branch continuations
/// (`else`/`and`/`option`) carry their condition as a `[…]` tag on
/// the dashed divider row.
///
/// Defensive: the frame paints into space (' '), lifeline (`┆`), and
/// activation-bar (`┃`) cells only — never overwrites a message arrow
/// or label glyph. This means heavily-populated rows may show partial
/// rails, which is the same trade-off the activation overlay accepts.
#[allow(clippy::too_many_arguments)]
fn draw_block_frame(
    canvas: &mut Canvas,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
    kind: &str,
    opener_label: &str,
    branches: &[(usize, &str)],
) {
    if right <= left || bottom <= top {
        return;
    }

    let paintable = |ch: char| -> bool { ch == ' ' || ch == LIFELINE || ch == ACTIVATION_BAR };

    // Top border with corners.
    if paintable(canvas.grid[top][left]) {
        canvas.put(top, left, '╔');
    }
    for c in (left + 1)..right {
        if paintable(canvas.grid[top][c]) {
            canvas.put(top, c, '═');
        }
    }
    if paintable(canvas.grid[top][right]) {
        canvas.put(top, right, '╗');
    }

    // Two-tag top border: `[kind]` badge then `[opener_label]` condition,
    // separated by `═` characters. Mermaid renders the kind as a small
    // corner badge with the condition floating beside it; this
    // monospace approximation preserves the same semantic split.
    let after_kind = draw_tag(canvas, top, left, kind);
    if !opener_label.is_empty() {
        // Inset the opener label 2 cells past the kind tag so an `═`
        // separator reads between them (e.g. `[alt]══[cache hit]`).
        draw_tag(canvas, top, after_kind, opener_label);
    }

    // Branch dividers (multi-branch blocks only) — drawn BEFORE the
    // side rails so the `╠`/`╣` junction glyphs claim the rail
    // intersection cells; the rails loop below skips divider rows.
    let divider_row_set: std::collections::HashSet<usize> =
        branches.iter().map(|(r, _)| *r).collect();
    for &(divider_row, branch_label) in branches {
        if divider_row <= top || divider_row >= bottom {
            continue;
        }
        // Side-rail intersections always claim ╠ / ╣ (these are
        // junction glyphs that semantically replace the rail).
        canvas.put(divider_row, left, '╠');
        canvas.put(divider_row, right, '╣');
        for c in (left + 1)..right {
            if paintable(canvas.grid[divider_row][c]) {
                canvas.put(divider_row, c, '┄');
            }
        }
        // Continuation label tag — same `draw_tag` helper as the top
        // border keeps the visual style consistent across all label
        // sites in the frame.
        draw_tag(canvas, divider_row, left, branch_label);
    }

    // Side rails on every row in (top, bottom), skipping divider rows
    // (already painted above with ╠/╣).
    for r in (top + 1)..bottom {
        if divider_row_set.contains(&r) {
            continue;
        }
        if paintable(canvas.grid[r][left]) {
            canvas.put(r, left, '║');
        }
        if paintable(canvas.grid[r][right]) {
            canvas.put(r, right, '║');
        }
    }

    // Bottom border with corners.
    if paintable(canvas.grid[bottom][left]) {
        canvas.put(bottom, left, '╚');
    }
    for c in (left + 1)..right {
        if paintable(canvas.grid[bottom][c]) {
            canvas.put(bottom, c, '═');
        }
    }
    if paintable(canvas.grid[bottom][right]) {
        canvas.put(bottom, right, '╝');
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::sequence::parse;

    #[test]
    fn activation_index_retains_inclusive_nested_boundaries() {
        let diag =
            parse("sequenceDiagram\nA->>+B: call\nA->>+B: inner\nB-->>-A: reply\nB-->>-A: done")
                .unwrap();
        let depths: Vec<_> = (0..diag.activations.len())
            .map(|index| activation_depth(&diag, index))
            .collect();
        let index = active_lane_index(&diag, &depths);
        let b = diag.participant_index("B").unwrap();
        assert_eq!(index[b], [(0, 2), (1, 5), (3, 2), (4, 0)]);
        assert_eq!(
            (0..5)
                .map(|at| active_width(&index[b], at))
                .collect::<Vec<_>>(),
            [2, 5, 5, 2, 0]
        );
        assert_eq!(active_width(&index[0], 2), 0);
    }

    #[test]
    fn canvas_preserves_combining_marks_at_the_final_display_column() {
        for (width, text) in [(1, "e\u{301}"), (2, "界\u{301}")] {
            let mut canvas = Canvas::new(width, 1);
            canvas.put_str(0, 0, text);
            assert_eq!(canvas.into_string(), text);
        }
    }

    #[test]
    fn canvas_blocked_wide_origin_cannot_hide_the_next_glyph() {
        let mut canvas = Canvas::new(4, 1);
        canvas.put_str(0, 0, "界AB");
        canvas.put_str(0, 1, "語\u{301}");
        assert_eq!(canvas.grid[0], ['界', '\0', 'A', 'B']);
        assert_eq!(canvas.into_string(), "界AB");
    }

    #[test]
    fn canvas_overlap_releases_both_columns_of_the_previous_wide_glyph() {
        let mut canvas = Canvas::new(4, 1);
        canvas.put_str(0, 1, "界\u{301}");
        canvas.put_str(0, 0, "語");
        canvas.put(0, 3, 'X');
        assert_eq!(canvas.grid[0], ['語', '\0', ' ', 'X']);
        assert_eq!(canvas.into_string(), "語 X");
    }

    #[test]
    fn canvas_serializes_wide_glyphs_without_continuation_cells() {
        let mut canvas = Canvas::new(4, 1);
        canvas.put_str(0, 0, "界\u{301}X");
        assert_eq!(canvas.into_string(), "界\u{301}X");
    }

    #[test]
    fn canvas_clips_wide_glyphs_at_the_right_edge() {
        let mut canvas = Canvas::new(1, 1);
        canvas.put_str(0, 0, "界");
        assert_eq!(canvas.into_string(), "");
    }

    #[test]
    fn render_produces_participant_boxes() {
        let diag = parse("sequenceDiagram\nparticipant A as Alice\nparticipant B as Bob").unwrap();
        let out = render(&diag, None);
        assert!(out.contains("Alice"), "missing Alice in:\n{out}");
        assert!(out.contains("Bob"), "missing Bob in:\n{out}");
        // Boxes use corner characters.
        assert!(out.contains('┌'), "no box corner in:\n{out}");
    }

    #[test]
    fn render_draws_lifelines() {
        let diag = parse("sequenceDiagram\nA->>B: hi").unwrap();
        let out = render(&diag, None);
        assert!(out.contains(LIFELINE), "no lifeline char in:\n{out}");
    }

    #[test]
    fn render_solid_arrow() {
        let diag = parse("sequenceDiagram\nA->>B: go").unwrap();
        let out = render(&diag, None);
        assert!(out.contains(ARROW_RIGHT), "no solid arrowhead in:\n{out}");
    }

    #[test]
    fn render_dashed_arrow() {
        let diag = parse("sequenceDiagram\nA-->>B: back").unwrap();
        let out = render(&diag, None);
        assert!(out.contains(H_DASH), "no dashed glyph in:\n{out}");
    }

    #[test]
    fn render_message_text_appears() {
        let diag = parse("sequenceDiagram\nA->>B: Hello Bob").unwrap();
        let out = render(&diag, None);
        assert!(out.contains("Hello Bob"), "missing message text in:\n{out}");
    }

    #[test]
    fn render_message_order_top_to_bottom() {
        let diag = parse("sequenceDiagram\nA->>B: first\nB->>A: second").unwrap();
        let out = render(&diag, None);
        let first_row = out
            .lines()
            .position(|l| l.contains("first"))
            .expect("'first' not found");
        let second_row = out
            .lines()
            .position(|l| l.contains("second"))
            .expect("'second' not found");
        assert!(
            first_row < second_row,
            "'first' should appear above 'second':\n{out}"
        );
    }

    #[test]
    fn render_empty_diagram_is_empty_string() {
        let diag = crate::sequence::SequenceDiagram::default();
        assert_eq!(render(&diag, None), "");
    }

    // -----------------------------------------------------------------------
    // Width-aware layout
    // -----------------------------------------------------------------------

    /// The row index of the box's bottom border for the participant whose label
    /// is `label`, or `None` if the label is not on the canvas.
    fn box_rows(out: &str, label: &str) -> (usize, usize) {
        let lines: Vec<&str> = out.lines().collect();
        let first = lines
            .iter()
            .position(|l| l.contains(label))
            .unwrap_or_else(|| panic!("{label} is not on the canvas:\n{out}"));
        // Walk out to the box's top and bottom borders.
        let top = (0..=first)
            .rev()
            .find(|&r| lines[r].contains('┌'))
            .expect("a box top border above the label");
        let bottom = (first..lines.len())
            .find(|&r| lines[r].contains('└'))
            .expect("a box bottom border below the label");
        (top, bottom)
    }

    #[test]
    fn a_wrapped_participant_label_makes_its_box_taller() {
        let diag = parse("sequenceDiagram\nparticipant A as Steering Service\nA->>A: ping").unwrap();

        let natural = render(&diag, None);
        let (natural_top, natural_bottom) = box_rows(&natural, "Steering Service");
        assert_eq!(
            natural_bottom - natural_top + 1,
            box_height(1),
            "an unwrapped label gets a one-line box:\n{natural}"
        );

        // A budget too small for the label forces it onto two rows, and the box
        // grows a row to hold them rather than clipping the label.
        let wrapped = render(&diag, Some(9));
        assert!(
            wrapped.contains("Steering") && wrapped.contains("Service"),
            "a wrapped label keeps every word:\n{wrapped}"
        );
        let (top, bottom) = box_rows(&wrapped, "Steering");
        assert_eq!(
            bottom - top + 1,
            box_height(2),
            "a two-line label gets a two-line box:\n{wrapped}"
        );
        assert_eq!(
            bottom - top + 1,
            natural_bottom - natural_top + 1 + 1,
            "and exactly one row taller than the unwrapped box"
        );
    }

    #[test]
    fn a_diagram_that_fits_its_budget_is_laid_out_exactly_as_without_one() {
        let diag = parse("sequenceDiagram\nA->>B: hello there\nB-->>A: hi back").unwrap();
        let natural = render(&diag, None);

        let roomy = render(&diag, Some(max_line_width(&natural) + 40));
        assert_eq!(
            roomy, natural,
            "a budget the natural layout already meets must change nothing"
        );

        let exact = render(&diag, Some(max_line_width(&natural)));
        assert_eq!(exact, natural, "a budget met exactly must change nothing");
    }

    #[test]
    fn an_over_wide_diagram_is_wrapped_until_it_fits() {
        // Every participant and every message label is long enough that the
        // natural layout is far wider than the budget.
        let diag = parse(
            "sequenceDiagram\n\
             participant A as Client Application\n\
             participant B as Gateway Router Service\n\
             participant C as Response Assembler\n\
             A->>B: a long enough request label to need wrapping\n\
             B->>C: and a long enough response to need it too",
        )
        .unwrap();

        let natural = render(&diag, None);
        let natural_width = max_line_width(&natural);
        // The floor is the three boxes side by side: `Application` and
        // `Assembler` are single words that word-wrapping cannot split, so the
        // boxes stay 17 and 15 columns wide however narrow the budget is. A
        // budget below that floor is `compacting_stops_at_the_floor_...`'s
        // subject; this test needs one that wrapping can actually reach.
        let budget = 80;
        assert!(
            natural_width > budget,
            "the fixture must start out wider than {budget}, got {natural_width}"
        );
        assert!(
            max_line_width(&render(&diag, Some(1))) < budget,
            "the fixture must be compactable to {budget}, but its floor is already \
             at or above it"
        );

        let compacted = render(&diag, Some(budget));
        let width = max_line_width(&compacted);
        assert!(
            width <= budget,
            "wrapping must bring {natural_width} columns within {budget}, got {width}:\n{compacted}"
        );

        // Nothing may be dropped on the way: every participant is still drawn,
        // and every word of every label survives somewhere on the canvas.
        for participant in ["Client Application", "Gateway Router Service", "Response Assembler"] {
            for word in participant.split_whitespace() {
                assert!(
                    compacted.contains(word),
                    "{word} went missing while compacting:\n{compacted}"
                );
            }
        }
        for word in "a long enough request label to need wrapping".split_whitespace() {
            assert!(
                compacted.contains(word),
                "message word {word} went missing while compacting:\n{compacted}"
            );
        }
    }

    #[test]
    fn compacting_stops_at_the_floor_rather_than_dropping_content() {
        // Three participants keep three boxes and their borders whatever the
        // budget, so there is a width below which wrapping cannot go.
        let diag = parse("sequenceDiagram\nA->>B: one\nB->>C: two").unwrap();

        let out = render(&diag, Some(1));
        assert!(!out.is_empty(), "a tiny budget must still produce a diagram");
        for name in ["A", "B", "C"] {
            assert!(out.contains(name), "participant {name} was dropped:\n{out}");
        }
        assert!(out.contains("one") && out.contains("two"), "messages dropped:\n{out}");
    }

    #[test]
    fn compaction_is_deterministic() {
        let src = "sequenceDiagram\nparticipant A as Client Application\nparticipant B as Server\nautonumber\nA->>B: a request long enough to wrap";
        let diag = parse(src).unwrap();
        let first = render(&diag, Some(40));
        let second = render(&diag, Some(40));
        assert_eq!(first, second, "the same budget must give the same layout");
    }

    /// With several arrangements inside the budget, the one emitted is the
    /// shortest — not the first the search reaches and not the narrowest.
    #[test]
    fn the_shortest_fitting_arrangement_is_emitted() {
        let src = "sequenceDiagram\n\
                   participant Alice as Alice Cooper\n\
                   participant Bob as Bob Dylan\n\
                   participant Carol as Carol King\n\
                   Alice->>Bob: the quick brown fox jumps over the lazy dog\n\
                   Bob->>Carol: a much shorter reply\n\
                   Carol-->>Alice: second message with several words in it\n\
                   Alice->>Carol: ok";
        let diag = parse(src).unwrap();
        let natural = render_wrapped(&diag, None);
        let natural_width = max_line_width(&natural);
        let budget = natural_width * 2 / 3;

        let out = render(&diag, Some(budget));
        let out_rows = out.lines().count();
        assert!(
            max_line_width(&out) <= budget,
            "the emitted arrangement must fit {budget}:\n{out}"
        );

        let mut fitting = 0;
        for target in 6..=natural_width {
            let candidate = render_wrapped(&diag, Some(target));
            if max_line_width(&candidate) <= budget {
                fitting += 1;
                let rows = candidate.lines().count();
                assert!(
                    rows >= out_rows,
                    "target {target} fits {budget} in {rows} rows, fewer than the \
                     {out_rows} emitted:\n{candidate}\n--- emitted ---\n{out}"
                );
            }
        }
        assert!(
            fitting > 1,
            "the fixture needs several fitting arrangements to prove anything"
        );
    }

    /// With nothing inside the budget, the narrowest arrangement is the one to
    /// emit: height buys the reader nothing when they are scrolling sideways
    /// anyway.
    #[test]
    fn with_no_fitting_arrangement_the_narrowest_is_emitted() {
        let src = "sequenceDiagram\n\
                   participant Alice as Alice Cooper\n\
                   participant Bob as Bob Dylan\n\
                   Alice->>Bob: the quick brown fox jumps over the lazy dog\n\
                   Bob-->>Alice: a much shorter reply\n\
                   Alice->>Bob: second message with several words in it";
        let diag = parse(src).unwrap();
        let natural = render_wrapped(&diag, None);
        let natural_width = max_line_width(&natural);

        let mut narrowest = natural_width;
        for target in 6..=natural_width {
            narrowest = narrowest.min(max_line_width(&render_wrapped(&diag, Some(target))));
        }

        let out = render(&diag, Some(1));
        assert_eq!(
            max_line_width(&out),
            narrowest,
            "a budget no arrangement fits must still yield the narrowest:\n{out}"
        );
    }

    /// A message label that shares its gap with an unbreakable token has room
    /// the first pass never gives it. Here the token pins the gap at 36 columns,
    /// so wrapping the other label to the target of 6 crushes it into four rows
    /// in a space that holds it in one.
    #[test]
    fn a_message_label_fills_the_gap_it_sits_in() {
        let src = "sequenceDiagram\nparticipant A\nparticipant B\n\
                   A->>B: a_very_long_unbreakable_token_here\n\
                   A->>B: one two three four";
        let diag = parse(src).unwrap();
        let tight = render_wrapped(&diag, Some(6));
        // The token decides the width, not the target, so filling the labels
        // must land on the same diagram a target as wide as the gap produces.
        let wide = render_wrapped(&diag, Some(40));
        assert_eq!(
            max_line_width(&tight),
            max_line_width(&wide),
            "filling a label must not widen the diagram:\n{tight}"
        );
        assert_eq!(
            tight.lines().count(),
            wide.lines().count(),
            "a label with room for one row must not take four:\n{tight}"
        );
        assert!(
            tight.contains("one two three four"),
            "the label should fill its gap:\n{tight}"
        );
    }

    /// A self-message's loop is sized from its own label, so it has no room to
    /// fill and is left at the target the first pass chose.
    #[test]
    fn a_self_message_label_is_left_at_the_target() {
        let src = "sequenceDiagram\nparticipant A\nA->>A: one two three four";
        let diag = parse(src).unwrap();
        let out = render_wrapped(&diag, Some(6));
        assert!(
            !out.contains("one two three four"),
            "a self-message has no gap to fill, so it stays wrapped:\n{out}"
        );
    }

    /// Compaction re-wraps labels; it must not drop one. Every word of every
    /// participant, message, note and block label has to reach the canvas, and
    /// every frame still has to be drawn.
    #[test]
    fn compaction_keeps_every_label_and_every_frame() {
        let src = "sequenceDiagram\n\
                   participant Client as Client Application\n\
                   participant Server as Application Server\n\
                   participant Store as Session Store\n\
                   Note over Client,Server: authentication begins here\n\
                   alt credentials valid\n\
                   Client->>Server: POST credentials payload\n\
                   Server->>Store: lookup session record\n\
                   Store-->>Server: session record found\n\
                   else credentials invalid\n\
                   Server-->>Client: reject request politely\n\
                   end\n\
                   loop retry policy\n\
                   Client->>Server: retry the request\n\
                   end";
        let diag = parse(src).unwrap();

        // Derived from the diagram rather than from the rendered output, so a
        // label missing from *both* would still fail here.
        let mut expected: Vec<String> = Vec::new();
        expected.extend(diag.participants.iter().map(|p| p.label.clone()));
        expected.extend(diag.messages.iter().map(|m| m.text.clone()));
        expected.extend(diag.notes.iter().map(|n| n.text.clone()));
        for block in &diag.blocks {
            expected.push(block_kind_label(block.kind.clone()).to_string());
            expected.extend(block.branches.iter().map(|b| b.label.clone()));
        }

        for target in [6, 12, 20] {
            let out = render_wrapped(&diag, Some(target));
            for text in &expected {
                for word in text.split_ascii_whitespace() {
                    assert!(
                        out.contains(word),
                        "target {target} lost {word:?} from {text:?}:\n{out}"
                    );
                }
            }
            // Every block frame still has a double-line top-left corner and
            // every note box a rounded one; participant boxes are `┌`.
            assert!(
                out.matches('╔').count() >= diag.blocks.len(),
                "target {target} lost a block frame:\n{out}"
            );
            assert!(
                out.matches('╭').count() >= diag.notes.len(),
                "target {target} lost a note frame:\n{out}"
            );
            assert!(
                out.matches('┌').count() >= diag.participants.len() * 2,
                "target {target} lost a participant box:\n{out}"
            );
        }
    }



}
