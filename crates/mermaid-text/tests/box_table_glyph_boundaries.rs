use mermaid_text::render::box_table::{
    draw_box, grid_to_string, grid_to_string_with_marks, put, put_str, put_str_with_marks,
};
use std::collections::HashMap;
use unicode_width::UnicodeWidthStr;

#[test]
fn public_box_keeps_combining_header_and_border_columns() {
    let mut grid = vec![vec![' '; 8]; 3];
    draw_box(&mut grid, 0, 0, 7, "e\u{301}X", &[]);
    let out = grid_to_string(&grid);
    assert_eq!(out, "┌──────┐\n│  e\u{301}X  │\n└──────┘");
    assert!(out.lines().all(|line| line.width() == 8));
}

#[test]
fn legacy_writes_keep_multiple_marks_and_coordinates() {
    let mut grid = vec![vec![' '; 5]];
    put_str(&mut grid, 0, 0, "界\u{301}\u{308}e\u{301}X");
    put(&mut grid, 0, 4, '|');
    assert_eq!(grid_to_string(&grid), "界\u{301}\u{308}e\u{301}X|");
    put_str(&mut grid, 0, 2, "AB");
    assert_eq!(grid_to_string(&grid), "界\u{301}\u{308}AB|");
    put(&mut grid, 0, 0, 'Z');
    assert_eq!(grid_to_string(&grid), "Z AB|");
}

#[test]
fn wide_glyphs_clip_and_final_cell_marks_survive() {
    for legacy in [true, false] {
        let mut grid = vec![vec![' '; 2]];
        let mut marks = HashMap::new();
        if legacy {
            put_str(&mut grid, 0, 1, "界");
        } else {
            put_str_with_marks(&mut grid, &mut marks, 0, 1, "界");
        }
        assert_eq!(grid_to_string_with_marks(&grid, &marks), "");
        if legacy {
            put_str(&mut grid, 0, 0, "界\u{301}\u{308}");
        } else {
            put_str_with_marks(&mut grid, &mut marks, 0, 0, "界\u{301}\u{308}");
        }
        assert_eq!(grid_to_string_with_marks(&grid, &marks), "界\u{301}\u{308}");
    }
}

#[test]
fn rejected_origin_does_not_attach_marks_to_previous_base() {
    let mut grid = vec![vec![' '; 5]];
    let mut marks = HashMap::new();
    put_str_with_marks(&mut grid, &mut marks, 0, 0, "界XYZ");
    put_str_with_marks(&mut grid, &mut marks, 0, 1, "語\u{301}B");
    assert_eq!(grid_to_string_with_marks(&grid, &marks), "界XBZ");
}

#[test]
fn overlapping_wide_write_clears_displaced_glyph_and_marks() {
    let mut grid = vec![vec![' '; 5]];
    let mut marks = HashMap::new();
    put_str_with_marks(&mut grid, &mut marks, 0, 1, "界\u{301}Z");
    put_str_with_marks(&mut grid, &mut marks, 0, 0, "語");
    assert_eq!(grid_to_string_with_marks(&grid, &marks), "語 Z");
    put_str_with_marks(&mut grid, &mut marks, 0, 2, "Q");
    assert_eq!(grid_to_string_with_marks(&grid, &marks), "語QZ");
}

#[test]
fn legacy_hline_bounds_allocation_and_preserves_inline_marks() {
    use mermaid_text::render::box_table::hline;
    let mut grid = vec![vec![' '; 6]];
    put_str(&mut grid, 0, 0, "e\u{301}");
    hline(&mut grid, 0, 2, usize::MAX, '┌', '┐');
    assert_eq!(grid_to_string(&grid), "e\u{301} ┌───");
}
