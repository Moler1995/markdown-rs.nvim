use mermaid_text::layout::grid::Grid;
use mermaid_text::render::box_table;
#[test]
fn combining_marks_survive_exact_canvas_boundary() {
    for (width, text) in [(1, "e\u{301}"), (2, "界\u{301}")] {
        let mut g = Grid::new(width, 1);
        g.write_text(0, 0, text);
        assert_eq!(g.to_string(), format!("{text}\n"));
        let mut g = Grid::new(width, 1);
        g.write_text_protected(0, 0, text);
        assert_eq!(g.to_string(), format!("{text}\n"));
    }
}
#[test]
fn blocked_wide_write_preserves_existing_neighbor() {
    let mut g = Grid::new(4, 1);
    g.write_text(0, 0, "界AB");
    assert_eq!(g.to_string(), "界AB\n");
    g.write_text(1, 0, "語");
    assert_eq!(
        g.to_string(),
        "界AB\n",
        "write into protected continuation must not hide neighboring A"
    );
}
#[test]
fn recomputed_base_releases_continuation() {
    let mut g = Grid::new(3, 1);
    g.write_text(0, 0, "界");
    g.recompute_cell_glyph(0, 0);
    g.set(1, 0, 'X');
    assert_eq!(g.to_string(), " X\n");
}
#[test]
fn legacy_box_table_combining_text_preserves_column_positions() {
    let mut g = vec![vec![' '; 3]];
    box_table::put_str(&mut g, 0, 0, "e\u{301}X");
    assert_eq!(box_table::grid_to_string(&g), "e\u{301}X");
    box_table::put(&mut g, 0, 2, 'Y');
    assert_eq!(box_table::grid_to_string(&g), "e\u{301}XY");
}
#[test]
fn legacy_box_table_wide_glyph_does_not_exceed_canvas() {
    let mut g = vec![vec![' '; 1]];
    box_table::put_str(&mut g, 0, 0, "界");
    assert_eq!(box_table::grid_to_string(&g), "");
}
#[test]
fn wide_overwrite_releases_old_glyphs_second_continuation() {
    let mut g = Grid::new(4, 1);
    g.write_text(1, 0, "界");
    assert_eq!(g.to_string(), " 界\n");
    g.write_text(0, 0, "語");
    g.set(3, 0, 'X');
    assert_eq!(
        g.to_string(),
        "語 X\n",
        "overlapping replacement must keep X at display column 3"
    );
}
#[test]
fn style_overdraw_releases_continuation_of_replaced_base() {
    let mut g = Grid::new(3, 1);
    g.write_text(0, 0, "界A");
    g.overdraw_path_style(&[(0, 0)], mermaid_text::layout::grid::EdgeLineStyle::Dotted);
    g.set(1, 0, 'X');
    assert_eq!(g.to_string(), " XA\n");
}

#[test]
fn marks_aware_box_writer_keeps_boundary_suffix() {
    for (width, text) in [(1, "e\u{301}"), (2, "界\u{301}")] {
        let mut grid = vec![vec![' '; width]];
        let mut marks = std::collections::HashMap::new();
        box_table::put_str_with_marks(&mut grid, &mut marks, 0, 0, text);
        assert_eq!(box_table::grid_to_string_with_marks(&grid, &marks), text);
    }
}
#[test]
fn quadrant_axis_keeps_exact_boundary_label() {
    let out = mermaid_text::render("quadrantChart\nx-axis low --> e\u{301}\n").unwrap();
    let line = out
        .lines()
        .find(|line| line.starts_with("low"))
        .expect("axis row");
    assert!(line.ends_with("e\u{301}"), "axis rendering: {out:?}");
}
