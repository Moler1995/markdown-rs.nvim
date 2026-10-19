//! Regressions for issue #52: wide Unicode glyphs must occupy two terminal
//! columns without exposing or overwriting their continuation cells.

use unicode_width::UnicodeWidthStr;

fn render(src: &str, ascii: bool) -> String {
    if ascii {
        mermaid_text::render_ascii(src)
    } else {
        mermaid_text::render(src)
    }
    .expect("valid CJK Mermaid diagram must render")
}

fn assert_contains_exact_label(out: &str, label: &str) {
    assert!(
        out.lines().any(|line| line.contains(label)),
        "expected contiguous label {label:?} in output:\n{out}"
    );
}

fn line_widths(out: &str) -> Vec<usize> {
    out.lines().map(UnicodeWidthStr::width).collect()
}

fn display_column_of_last(line: &str, needle: char) -> Option<usize> {
    let (mut last, mut col) = (None, 0);
    for ch in line.chars() {
        if ch == needle {
            last = Some(col);
        }
        col += unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
    }
    last
}

fn display_column_of_first(line: &str, needle: char) -> Option<usize> {
    let mut col = 0;
    for ch in line.chars() {
        if ch == needle {
            return Some(col);
        }
        col += unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
    }
    None
}

#[test]
fn flowchart_cjk_labels_are_contiguous_and_ascii_keeps_node_geometry() {
    let src = "flowchart LR\n  A[開始Ａ] --> B[終了]\n";
    for ascii in [false, true] {
        let out = render(src, ascii);
        assert_contains_exact_label(&out, "開始Ａ");
        assert_contains_exact_label(&out, "終了");

        let rows: Vec<&str> = out.lines().collect();
        let label_row = rows
            .iter()
            .find(|line| line.contains("開始Ａ"))
            .expect("source node label row missing");
        let right_border = if ascii { '|' } else { '│' };
        assert!(
            label_row.contains(&format!("{right_border} 開始Ａ {right_border}")),
            "node padding or label geometry changed:\n{out}"
        );
        let label_right =
            display_column_of_last(label_row, right_border).expect("right node border missing");
        let top_row = rows
            .iter()
            .find(|line| line.contains(if ascii { '+' } else { '┐' }))
            .expect("source node top border missing");
        let top_right = display_column_of_last(top_row, if ascii { '+' } else { '┐' })
            .expect("source node top-right corner missing");
        assert_eq!(
            label_right, top_right,
            "source label and top border right edges differ:\n{out}"
        );
        let widths = line_widths(&out);
        assert_eq!(
            widths.iter().min(),
            widths.iter().max(),
            "rendered rows have inconsistent terminal widths:\n{out}"
        );
    }
}

#[test]
fn combining_marks_remain_attached_in_unicode_and_ascii_modes() {
    let src = "flowchart LR\n  A[語\u{301}e\u{301}] --> B[終]\n";
    for ascii in [false, true] {
        let out = render(src, ascii);
        assert_contains_exact_label(&out, "語\u{301}e\u{301}");
        assert_contains_exact_label(&out, "終");
    }
}

#[test]
fn sequence_message_and_alt_text_are_not_split_or_painted_over() {
    let out = render(
        "sequenceDiagram\n  A->>B: 要件定義書\n  alt 成功\n    B->>A: 承\u{301}認\n  end\n",
        false,
    );
    assert_contains_exact_label(&out, "要件定義書");
    assert_contains_exact_label(&out, "成功");
    assert_contains_exact_label(&out, "承\u{301}認");
    assert!(
        !out.contains("成═功") && !out.contains("成┄功") && !out.contains("承┆認"),
        "frame/lifeline glyph overwrote a CJK continuation cell:\n{out}"
    );
}

#[test]
fn class_and_er_box_table_labels_keep_their_display_width() {
    for src_label in [
        "classDiagram\n  class 動物 {\n    +名前\n  }\n",
        "erDiagram\n  顧客 ||--o{ 注文 : places\n",
    ] {
        let out = render(src_label, false);
        let expected = if src_label.starts_with("classDiagram") {
            "動物"
        } else {
            "顧客"
        };
        assert_contains_exact_label(&out, expected);
        if expected == "動物" {
            assert_contains_exact_label(&out, "+名前");
        }
        let rows: Vec<&str> = out.lines().collect();
        let expected_width = line_widths(&out).into_iter().max().unwrap_or_default();
        let label_row = rows
            .iter()
            .find(|row| row.contains(expected))
            .expect("label row missing");
        assert_eq!(
            label_row.width(),
            expected_width,
            "box-table label row does not reach canvas right edge:\n{out}"
        );
        let (top_cap, body_border) = if expected == "動物" {
            ('┐', '│')
        } else {
            ('┐', '┤')
        };
        let top_right = rows
            .iter()
            .find_map(|row| display_column_of_first(row, top_cap))
            .expect("box top-right border missing");
        let right_edge = if expected == "動物" {
            display_column_of_last(label_row, body_border)
        } else {
            display_column_of_first(label_row, body_border)
        }
        .expect("label row right border missing");
        assert_eq!(
            right_edge, top_right,
            "box-table label row border is misaligned:\n{out}"
        );
        if expected == "動物" {
            let body_row = rows
                .iter()
                .find(|row| row.contains("+名前"))
                .expect("member row missing");
            assert_eq!(
                display_column_of_last(body_row, '│'),
                Some(top_right),
                "member row right border is misaligned:\n{out}"
            );
        }
    }
}

#[test]
fn combining_marks_stay_attached_inside_class_and_er_boxes() {
    for (src, label, body) in [
        (
            "classDiagram\n  class e\u{301}X {\n    +名e\u{301}X\n  }\n",
            "e\u{301}X",
            "+名e\u{301}X",
        ),
        (
            "erDiagram\n  Customer {\n    string 名e\u{301}X\n  }\n",
            "Customer",
            "名e\u{301}X",
        ),
    ] {
        let out = render(src, false);
        assert_contains_exact_label(&out, label);
        assert_contains_exact_label(&out, body);
        let rows: Vec<&str> = out.lines().collect();
        let top_right = rows
            .iter()
            .find_map(|row| display_column_of_first(row, '┐'))
            .expect("box top-right border missing");
        let label_row = rows.iter().find(|row| row.contains(label)).unwrap();
        let right_border =
            display_column_of_last(label_row, '│').expect("label row right border missing");
        assert_eq!(
            right_border, top_right,
            "combining mark changed boxed border geometry:\n{out}"
        );
        let body_row = rows.iter().find(|row| row.contains(body)).unwrap();
        assert_eq!(
            display_column_of_last(body_row, '│'),
            Some(top_right),
            "combining mark changed member-row border geometry:\n{out}"
        );
        assert_eq!(
            body_row.width(),
            top_right + 1,
            "combining mark changed member-row display width:\n{out}"
        );
    }
}

#[test]
fn quadrant_and_xy_chart_canvas_labels_remain_contiguous() {
    let quadrant = render(
        "quadrantChart\n  title 日本語\n  x-axis 低 --> 高\n  y-axis 低 --> 高\n  日本語点: [0.25, 0.75]\n",
        false,
    );
    assert_contains_exact_label(&quadrant, "日本語");
    assert_contains_exact_label(&quadrant, "低");
    assert_contains_exact_label(&quadrant, "日本語点 (0.25,0.75)");

    let edge_point = render("quadrantChart\n  日本e\u{301}点: [1.0, 0.75]\n", false);
    let point_row = edge_point
        .lines()
        .find(|line| line.contains("日本e\u{301}点"))
        .expect("right-edge point label missing");
    assert_contains_exact_label(&edge_point, "日本e\u{301}点 (1.00,0.75)");
    assert_eq!(
        display_column_of_last(point_row, '·'),
        Some(69),
        "wide point label shifted the marker from its x coordinate:\n{edge_point}"
    );

    let xy = render(
        "xychart-beta\n  title 日本語\n  x-axis [開始, 終了]\n  bar [1, 2]\n",
        false,
    );
    assert_contains_exact_label(&xy, "日本語");
    assert_contains_exact_label(&xy, "開始");
    assert_contains_exact_label(&xy, "終了");
    let category_row = xy
        .lines()
        .find(|line| line.contains("開始") && line.contains("終了"))
        .expect("category labels must share their x-axis row");
    assert!(
        category_row.find("開始").unwrap() < category_row.find("終了").unwrap(),
        "category slot order changed:\n{xy}"
    );
    assert!(
        category_row.width() <= 72,
        "category labels exceed the chart canvas display width:\n{xy}"
    );
}
