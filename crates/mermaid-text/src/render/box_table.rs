//! Shared primitive for drawing labelled box-table widgets on a character grid.
//!
//! A "box table" is a Unicode box-drawing rectangle with:
//! - a centred **header** row (the entity/class name),
//! - an optional horizontal **divider** after the header,
//! - zero or more **body rows** of left-aligned text columns,
//! - a closing **bottom border**.
//!
//! Used by both [`crate::render::er`] (entity boxes with type/name/key columns)
//! and [`crate::render::class`] (class boxes with visibility/member columns).
//!
//! # Design invariants
//!
//! - Drawing uses a `&mut [Vec<char>]` grid slice with NUL continuation markers
//!   for wide glyphs. Legacy helpers store combining scalars inline; marked
//!   helpers keep them in a sidecar and retain fixed-cell rows.
//! - `put` and `put_str` are bounds-checked and silently drop out-of-bounds
//!   writes, so callers do not need to track whether a coordinate is valid.
//! - `pad_right` produces display-width-aware padding using [`unicode_width`].
//! - `NAME_PAD` is the standard interior horizontal padding for all box types.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Cells of padding inside a box on each side of content.
///
/// Applied to the header name and to each body column's leading indent.
pub const NAME_PAD: usize = 2;

// ---------------------------------------------------------------------------
// Low-level grid helpers
// ---------------------------------------------------------------------------

/// Write a single character into `grid[row][col]`, silently ignoring
/// out-of-bounds coordinates.
pub(crate) fn put_cell(grid: &mut [Vec<char>], row: usize, col: usize, ch: char) {
    if let Some(line) = grid.get_mut(row) {
        if col >= line.len() || line[col] == '\0' {
            return;
        }
        if col + 1 < line.len() && line[col + 1] == '\0' {
            line[col + 1] = ' ';
        }
        line[col] = ch;
    }
}

/// Write a glyph at a terminal column, retaining inline combining scalars.
pub fn put(grid: &mut [Vec<char>], row: usize, col: usize, ch: char) {
    put_str(grid, row, col, &ch.to_string());
}

/// Write text at terminal columns. Combining scalars are stored inline without
/// consuming columns; subsequent public writes retain the same coordinates.
pub fn put_str(grid: &mut [Vec<char>], row: usize, col: usize, s: &str) {
    let Some(line) = grid.get_mut(row) else {
        return;
    };
    let mut cells = Vec::with_capacity(line.len());
    let mut marks = std::collections::HashMap::<(usize, usize), String>::new();
    let mut last = None;
    for &ch in line.iter() {
        if ch != '\0' && UnicodeWidthChar::width(ch) == Some(0) {
            if let Some(base) = last {
                marks.entry((0, base)).or_default().push(ch);
            }
        } else {
            if ch != '\0' {
                last = Some(cells.len());
            }
            cells.push(ch);
        }
    }
    put_str_with_marks(std::slice::from_mut(&mut cells), &mut marks, 0, col, s);
    line.clear();
    for (col, ch) in cells.into_iter().enumerate() {
        line.push(ch);
        if let Some(suffix) = marks.get(&(0, col)) {
            line.extend(suffix.chars());
        }
    }
}

/// Write text into a character grid while retaining combining marks beside
/// their base glyph. The map is keyed by `(row, column)` of that base glyph.
pub fn put_str_with_marks(
    grid: &mut [Vec<char>],
    marks: &mut std::collections::HashMap<(usize, usize), String>,
    row: usize,
    col: usize,
    s: &str,
) {
    put_str_clipped(grid, marks, row, col, s, usize::MAX);
}

/// Shared fixed-cell writer with an exclusive terminal-column limit.
pub(crate) fn put_str_clipped(
    grid: &mut [Vec<char>],
    marks: &mut std::collections::HashMap<(usize, usize), String>,
    row: usize,
    col: usize,
    s: &str,
    max_col: usize,
) {
    let Some(line) = grid.get_mut(row) else {
        return;
    };
    let limit = max_col.min(line.len());
    let mut c = col;
    let mut last_glyph = None;
    for ch in s.chars() {
        let char_width = UnicodeWidthChar::width(ch).unwrap_or(1);
        if char_width == 0 {
            if let Some(glyph_col) = last_glyph {
                marks.entry((row, glyph_col)).or_default().push(ch);
            }
            continue;
        }
        if c >= limit || char_width == 2 && c + 1 >= limit {
            break;
        }
        if line[c] == '\0' {
            last_glyph = None;
            c += char_width;
            continue;
        }
        for replaced in c..c + char_width {
            marks.remove(&(row, replaced));
            if replaced + 1 < line.len() && line[replaced + 1] == '\0' {
                line[replaced + 1] = ' ';
                marks.remove(&(row, replaced + 1));
            }
        }
        line[c] = ch;
        last_glyph = Some(c);
        if char_width == 2 && c + 1 < line.len() {
            line[c + 1] = '\0';
        }
        c += char_width;
    }
}

/// Pad `s` with trailing spaces so its display width equals exactly `width`
/// terminal cells.
///
/// If `s` is already `>= width` cells wide, it is returned unchanged
/// (no truncation). Uses [`UnicodeWidthStr::width`] for correctness with
/// multi-byte and wide characters.
pub fn pad_right(s: &str, width: usize) -> String {
    let current = s.width();
    if current >= width {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + (width - current));
    out.push_str(s);
    for _ in current..width {
        out.push(' ');
    }
    out
}

/// Serialise a `char` grid to a `String`, trimming trailing whitespace from
/// each row and trailing blank lines from the end.
pub fn grid_to_string(grid: &[Vec<char>]) -> String {
    grid_to_string_with_marks(grid, &std::collections::HashMap::new())
}

/// Serialise a grid and append any combining marks to their base glyphs.
pub fn grid_to_string_with_marks(
    grid: &[Vec<char>],
    marks: &std::collections::HashMap<(usize, usize), String>,
) -> String {
    let mut out = String::with_capacity(grid.iter().map(|r| r.len() + 1).sum());
    for (row_idx, row) in grid.iter().enumerate() {
        let mut line = String::new();
        let mut col = 0;
        for &ch in row {
            if ch != '\0' {
                line.push(ch);
                if UnicodeWidthChar::width(ch) == Some(0) {
                    continue;
                }
                if let Some(suffix) = marks.get(&(row_idx, col)) {
                    line.push_str(suffix);
                }
            }
            col += 1;
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    while out.ends_with('\n') {
        out.pop();
    }
    out
}

// ---------------------------------------------------------------------------
// Box-drawing primitives
// ---------------------------------------------------------------------------

/// Draw a horizontal rule of `─` glyphs from `(row, left)` to `(row, right)`
/// inclusive, with `left_cap` and `right_cap` corner/tee glyphs at the ends.
///
/// Used for top borders (`┌` … `┐`), dividers (`├` … `┤`), and bottom
/// borders (`└` … `┘`).
pub fn hline(
    grid: &mut [Vec<char>],
    row: usize,
    left: usize,
    right: usize,
    left_cap: char,
    right_cap: char,
) {
    let Some(line) = grid.get(row) else { return };
    let middle = "─".repeat(right.saturating_sub(left.saturating_add(1)).min(line.len()));
    put_str(grid, row, left, &format!("{left_cap}{middle}"));
    put(grid, row, right, right_cap);
}

/// Draw the full box for a labelled box-table entity.
///
/// Layout (each item is one row):
///
/// ```text
/// ┌──────────────┐      ← top border
/// │    Header    │      ← centred header text
/// ├──────────────┤      ← divider (only if rows.len() > 0)
/// │ col0  col1   │      ← body row 0
/// │ col0  col1   │      ← body row 1
/// └──────────────┘      ← bottom border
/// ```
///
/// When `rows` is empty the box collapses to 3 rows (top + header +
/// bottom, no divider).
///
/// # Arguments
///
/// * `grid`     — mutable character grid to paint into
/// * `top_pad`  — number of rows above this box (used as the row offset)
/// * `left`     — column of the left border (`│`)
/// * `right`    — column of the right border (`│`); `right - left - 1` = interior width
/// * `header`   — text centred in the header row
/// * `rows`     — body rows; each row is a slice of pre-formatted column
///   strings that are written left-to-right with one space between columns.
///   Pass an empty slice for a header-only box.
pub fn draw_box(
    grid: &mut [Vec<char>],
    top_pad: usize,
    left: usize,
    right: usize,
    header: &str,
    rows: &[Vec<String>],
) {
    let interior_w = right - left - 1;
    let header_w = header.width();
    let name_start = left + 1 + (interior_w.saturating_sub(header_w)) / 2;

    // Top border.
    hline(grid, top_pad, left, right, '┌', '┐');

    // Header row — centred.
    put(grid, top_pad + 1, left, '│');
    put_str(grid, top_pad + 1, name_start, header);
    put(grid, top_pad + 1, right, '│');

    if rows.is_empty() {
        // No body rows — close immediately after the header.
        hline(grid, top_pad + 2, left, right, '└', '┘');
        return;
    }

    // Divider between header and body.
    hline(grid, top_pad + 2, left, right, '├', '┤');

    // Body rows. Each row's columns are concatenated with a single space
    // separator and written left-aligned starting after `NAME_PAD` indent.
    for (i, row_cols) in rows.iter().enumerate() {
        let row_idx = top_pad + 3 + i;
        put(grid, row_idx, left, '│');
        let text = row_cols.join(" ");
        put_str(grid, row_idx, left + 1 + NAME_PAD, &text);
        put(grid, row_idx, right, '│');
    }

    // Bottom border.
    let bottom = top_pad + 3 + rows.len();
    hline(grid, bottom, left, right, '└', '┘');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_grid(rows: usize, cols: usize) -> Vec<Vec<char>> {
        vec![vec![' '; cols]; rows]
    }

    #[test]
    fn put_writes_char_in_bounds() {
        let mut g = make_grid(3, 5);
        put(&mut g, 1, 2, 'X');
        assert_eq!(g[1][2], 'X');
    }

    #[test]
    fn put_ignores_out_of_bounds() {
        let mut g = make_grid(2, 2);
        put(&mut g, 5, 5, 'Z'); // must not panic
    }

    #[test]
    fn put_str_writes_consecutive_chars() {
        let mut g = make_grid(1, 10);
        put_str(&mut g, 0, 2, "hello");
        let s: String = g[0].iter().collect();
        assert_eq!(s.trim_end(), "  hello");
    }

    #[test]
    fn pad_right_pads_to_exact_width() {
        assert_eq!(pad_right("ab", 5), "ab   ");
        assert_eq!(pad_right("abcde", 5), "abcde");
        assert_eq!(pad_right("abcdef", 5), "abcdef"); // no truncation
    }

    #[test]
    fn grid_to_string_trims_trailing_whitespace_and_newlines() {
        let grid = vec![vec!['a', ' ', ' '], vec![' ', ' ', ' ']];
        assert_eq!(grid_to_string(&grid), "a");
    }

    #[test]
    fn hline_draws_correct_glyphs() {
        let mut g = make_grid(1, 8);
        hline(&mut g, 0, 0, 7, '┌', '┐');
        assert_eq!(g[0][0], '┌');
        assert_eq!(g[0][7], '┐');
        for cell in g[0].iter().take(7).skip(1) {
            assert_eq!(*cell, '─');
        }
    }

    #[test]
    fn draw_box_header_only_produces_three_rows() {
        let mut g = make_grid(3, 12);
        draw_box(&mut g, 0, 0, 11, "Foo", &[]);
        assert_eq!(g[0][0], '┌');
        assert_eq!(g[2][0], '└');
        // No row 3 means the grid row at index 3 stays blank.
    }

    #[test]
    fn draw_box_with_rows_produces_divider_and_body() {
        let mut g = make_grid(6, 16);
        let rows = vec![vec!["int".to_string(), "id".to_string()]];
        draw_box(&mut g, 0, 0, 15, "MyClass", &rows);
        // Divider row
        assert_eq!(g[2][0], '├');
        assert_eq!(g[2][15], '┤');
        // Body row
        assert_eq!(g[3][0], '│');
        // Bottom border
        assert_eq!(g[4][0], '└');
    }
}
