use std::collections::VecDeque;

use mermaid_text::{render, render_ascii};

const STATE_NOTE: &str = "stateDiagram-v2\n[*] --> Idle\nnote left of Idle\n  draft\nend note";

const NESTED_SEQUENCE: &str = "sequenceDiagram\nAlice->>Bob: one\nactivate Bob\nBob->>Carol: two\nactivate Carol\nCarol-->>Bob: three\ndeactivate Carol\nBob-->>Alice: four\ndeactivate Bob";

const SAME_PARTICIPANT_NESTING: &str = "sequenceDiagram\nA->>B: outer call\nactivate B\nA->>B: inner call\nactivate B\nB->>A: inner reply\ndeactivate B\nB->>A: outer reply\ndeactivate B";

fn lines(rendered: &str) -> Vec<Vec<char>> {
    rendered
        .lines()
        .map(|line| line.chars().collect())
        .collect()
}

// Ports are N/E/S/W. A connector is continuous only when neighboring
// cells expose compatible ports, rather than merely touching each other.
fn ports(ch: char) -> u8 {
    match ch {
        '┆' | '┊' | '│' | '|' | ':' => 1 | 4,
        '┄' | '┈' | '─' | '-' | '.' => 2 | 8,
        '┌' | '╭' => 2 | 4,
        '┐' | '╮' => 4 | 8,
        '└' | '╰' => 1 | 2,
        '┘' | '╯' => 1 | 8,
        '+' => 1 | 2 | 4 | 8,
        _ => 0,
    }
}

fn assert_note_connector_is_continuous(rendered: &str) {
    let grid = lines(rendered);
    let note_row = grid
        .iter()
        .position(|row| row.iter().collect::<String>().contains("draft"))
        .unwrap();
    let note_right = grid[note_row]
        .iter()
        .rposition(|ch| matches!(ch, '│' | '|'))
        .unwrap();
    let state_row = grid
        .iter()
        .position(|row| row.iter().collect::<String>().contains("Idle"))
        .unwrap();
    let state_left = grid[state_row]
        .iter()
        .position(|ch| matches!(ch, '│' | '|'))
        .unwrap();
    let state_right = grid[state_row]
        .iter()
        .rposition(|ch| matches!(ch, '│' | '|'))
        .unwrap();
    let target = |r: usize, c: usize| {
        (r == state_row && (c == state_left || c == state_right))
            || ((r == state_row - 1 || r == state_row + 1)
                && (state_left..=state_right).contains(&c))
    };
    let start = (note_row, note_right + 1);
    assert_ne!(
        ports(grid[start.0][start.1]) & 8,
        0,
        "note must attach to first connector:\n{rendered}"
    );
    let mut queue = VecDeque::from([start]);
    let mut seen = std::collections::HashSet::from([start]);
    let mut reached = false;
    while let Some((r, c)) = queue.pop_front() {
        for (nr, nc, outgoing, incoming) in [
            (r.wrapping_sub(1), c, 1, 4),
            (r, c + 1, 2, 8),
            (r + 1, c, 4, 1),
            (r, c.wrapping_sub(1), 8, 2),
        ] {
            if nr >= grid.len() || nc >= grid[nr].len() || ports(grid[r][c]) & outgoing == 0 {
                continue;
            }
            if target(nr, nc) {
                reached = true;
                break;
            }
            if ports(grid[nr][nc]) & incoming != 0 && seen.insert((nr, nc)) {
                queue.push_back((nr, nc));
            }
        }
    }
    assert!(
        reached,
        "directionally disconnected note-to-state route:\n{rendered}"
    );
}

fn assert_labels_clear_of_activation_bars(rendered: &str, bar: char, labels: &[&str]) {
    let lines: Vec<&str> = rendered.lines().collect();
    for &label in labels {
        let row = lines
            .iter()
            .find(|line| line.contains(label))
            .unwrap_or_else(|| panic!("message label `{label}` missing:\n{rendered}"));
        let start = row.find(label).expect("label just found");
        let label_cells = &row[start..start + label.len()];
        assert!(
            !label_cells.contains(bar),
            "activation bar overlaps message label `{label}` in row `{row}`:\n{rendered}"
        );
        let message_prefix = &row[..start];
        assert!(
            !message_prefix.ends_with(bar),
            "activation bar touches message label `{label}` with no clearance in row `{row}`:\n{rendered}"
        );
        let after_label = &row[start + label.len()..];
        assert!(
            !after_label.starts_with(bar),
            "activation bar touches message label `{label}` with no clearance in row `{row}`:\n{rendered}"
        );
    }
}

#[test]
fn left_state_note_connector_is_continuous_in_unicode_and_ascii() {
    let unicode = render(STATE_NOTE).unwrap();
    assert_note_connector_is_continuous(&unicode);

    let ascii = render_ascii(STATE_NOTE).unwrap();
    assert_note_connector_is_continuous(&ascii);
}

#[test]
fn nested_sequence_activation_bars_clear_message_labels_in_unicode_and_ascii() {
    let unicode = render(NESTED_SEQUENCE).unwrap();
    assert_labels_clear_of_activation_bars(&unicode, '█', &["one", "two", "three", "four"]);

    let ascii = render_ascii(NESTED_SEQUENCE).unwrap();
    assert_labels_clear_of_activation_bars(&ascii, '#', &["one", "two", "three", "four"]);

    let same_participant_unicode = render(SAME_PARTICIPANT_NESTING).unwrap();
    assert_labels_clear_of_activation_bars(
        &same_participant_unicode,
        '█',
        &["outer call", "inner call", "inner reply", "outer reply"],
    );

    let same_participant_ascii = render_ascii(SAME_PARTICIPANT_NESTING).unwrap();
    assert_labels_clear_of_activation_bars(
        &same_participant_ascii,
        '#',
        &["outer call", "inner call", "inner reply", "outer reply"],
    );
}

// Each expected lane must consist of exactly two blocks on every row in its
// declared span, and contain no blocks outside it. Removing bars cannot pass.
fn assert_lanes(out: &str, bar: char, spans: &[(usize, usize, usize)]) {
    let grid = lines(out);
    let mut actual = std::collections::HashSet::new();
    for (row, cells) in grid.iter().enumerate() {
        for (col, &ch) in cells.iter().enumerate() {
            if ch == bar {
                actual.insert((row, col));
            }
        }
    }
    let expected: std::collections::HashSet<_> = spans
        .iter()
        .flat_map(|&(col, lo, hi)| (lo..=hi).flat_map(move |row| [(row, col), (row, col + 1)]))
        .collect();
    assert_eq!(actual, expected, "activation lanes drifted:\n{out}");
}

fn center(out: &str, name: &str) -> usize {
    let row = out.lines().nth(1).unwrap();
    let name_start = row
        .chars()
        .collect::<Vec<_>>()
        .windows(name.len())
        .position(|cs| cs.iter().collect::<String>() == name)
        .unwrap();
    let cells: Vec<_> = row.chars().collect();
    let left = (0..name_start)
        .rfind(|&i| matches!(cells[i], '│' | '|'))
        .unwrap();
    let right = (name_start..cells.len())
        .find(|&i| matches!(cells[i], '│' | '|'))
        .unwrap();
    left + (right - left).div_ceil(2)
}

#[test]
fn activation_spans_are_exact_continuous_and_distinct() {
    for (render, bar) in [
        (
            mermaid_text::render as fn(&str) -> Result<String, mermaid_text::Error>,
            '█',
        ),
        (
            mermaid_text::render_ascii as fn(&str) -> Result<String, mermaid_text::Error>,
            '#',
        ),
    ] {
        let out = render(NESTED_SEQUENCE).unwrap();
        let bob = center(&out, "Bob");
        let carol = center(&out, "Carol");
        assert_lanes(&out, bar, &[(bob, 5, 10), (carol, 7, 8)]);
        let out = render(SAME_PARTICIPANT_NESTING).unwrap();
        let b = center(&out, "B");
        assert_lanes(&out, bar, &[(b, 5, 10), (b + 3, 7, 8)]);
        let out = render("sequenceDiagram\nA->>B: call\nactivate B\nactivate B\nB->>B: self\ndeactivate B\ndeactivate B").unwrap();
        let b = center(&out, "B");
        assert_lanes(&out, bar, &[(b, 5, 8), (b + 3, 5, 8)]);
        assert_labels_clear_of_activation_bars(&out, bar, &["call", "self"]);
    }
}

fn exact_note(out: &str, ascii: bool, top: usize, left: usize, width: usize, text: &str) {
    let rows = lines(out);
    let horizontal = if ascii { '-' } else { '─' };
    let expected = [
        format!(
            "{}{}{}",
            if ascii { '+' } else { '╭' },
            horizontal.to_string().repeat(width - 2),
            if ascii { '+' } else { '╮' }
        ),
        format!(
            "{} {}{}{}",
            if ascii { '|' } else { '│' },
            text,
            " ".repeat(width - text.len() - 3),
            if ascii { '|' } else { '│' }
        ),
        format!(
            "{}{}{}",
            if ascii { '+' } else { '╰' },
            horizontal.to_string().repeat(width - 2),
            if ascii { '+' } else { '╯' }
        ),
    ];
    for (offset, expected) in expected.iter().enumerate() {
        let actual: String = rows[top + offset].iter().skip(left).take(width).collect();
        assert_eq!(
            &actual, expected,
            "note row {offset} must remain exact:\n{out}"
        );
    }
}

#[test]
fn nested_right_of_note_reserves_both_activation_lanes() {
    let src = "sequenceDiagram\nA->>+B: call\nA->>+B: inner\nnote right of B: exact note\nB-->>-A: reply\nB-->>-A: done";
    for ascii in [false, true] {
        let out = if ascii {
            render_ascii(src)
        } else {
            render(src)
        }
        .unwrap();
        let b = center(&out, "B");
        exact_note(&out, ascii, 8, b + 7, 14, "exact note");
        assert_lanes(
            &out,
            if ascii { '#' } else { '█' },
            &[(b, 3, 14), (b + 3, 5, 12)],
        );
    }
}

#[test]
fn over_notes_are_opaque_and_exposed_lanes_remain_continuous() {
    for (src, pair, top, text) in [
        (
            "sequenceDiagram\nA->>+B: call\nnote over B: exact note\nB-->>-A: done",
            false,
            6,
            "exact note",
        ),
        (
            "sequenceDiagram\nparticipant A\nparticipant B\nparticipant C\nA->>+B: call\nA->>+B: inner\nnote over B,C: exact pair\nB-->>-A: reply\nB-->>-A: done",
            true,
            8,
            "exact pair",
        ),
    ] {
        for ascii in [false, true] {
            let out = if ascii {
                render_ascii(src)
            } else {
                render(src)
            }
            .unwrap();
            let b = center(&out, "B");
            let (left, width) = if pair {
                let c = center(&out, "C");
                let width = (text.len() + 4).max(c - b + 3);
                ((b + c) / 2 - width / 2, width)
            } else {
                (b - (text.len() + 4) / 2, text.len() + 4)
            };
            exact_note(&out, ascii, top, left, width, text);
            let bar = if ascii { '#' } else { '█' };
            let mut spans = vec![(b, 3, top - 1), (b, top + 3, if pair { 14 } else { 10 })];
            if pair {
                spans.extend([(b + 3, 5, top - 1), (b + 3, top + 3, 12)]);
            }
            assert_lanes(&out, bar, &spans);
        }
    }
}

#[test]
fn notes_at_one_boundary_keep_source_order_and_original_over_anchor() {
    let src = "sequenceDiagram\nA->>+B: call\nnote over B: first note\nnote right of B: second note\nB-->>-A: done";
    for ascii in [false, true] {
        let out = if ascii {
            render_ascii(src)
        } else {
            render(src)
        }
        .unwrap();
        let b = center(&out, "B");
        exact_note(&out, ascii, 6, b - 7, 14, "first note");
        exact_note(&out, ascii, 10, b + 4, 15, "second note");
        assert_lanes(
            &out,
            if ascii { '#' } else { '█' },
            &[(b, 3, 5), (b, 9, 14)],
        );
    }
}

#[test]
fn unknown_public_messages_do_not_shift_valid_activation_indices_or_drop_notes() {
    let mut diagram =
        mermaid_text::parser::sequence::parse("sequenceDiagram\nA->>+B: call\nB-->>-A: done")
            .unwrap();
    let mut unknown = diagram.messages[0].clone();
    unknown.from = "unknown".into();
    diagram.messages.insert(0, unknown);
    for activation in &mut diagram.activations {
        activation.start_message += 1;
        activation.end_message += 1;
    }
    let out = mermaid_text::render::sequence::render(&diagram);
    let b = center(&out, "B");
    assert_lanes(&out, '█', &[(b, 3, 6)]);
    diagram.notes.push(mermaid_text::sequence::NoteEvent {
        anchor: mermaid_text::sequence::NoteAnchor::Over("A".into()),
        text: "boundary note".into(),
        after_message: 1,
    });
    let out = mermaid_text::render::sequence::render(&diagram);
    exact_note(&out, false, 4, 0, 17, "boundary note");
}

#[test]
fn autonumber_labels_fit_before_active_intermediate_and_inside_self_loop() {
    let src = "sequenceDiagram\nparticipant A\nparticipant B\nparticipant C\nautonumber 1000000000\nactivate B\nA->>C: abcdefghijklmnopqrstuvwxy\ndeactivate B";
    let expected = "[1000000000] abcdefghijklmnopqrstuvwxy";
    for ascii in [false, true] {
        let out = if ascii {
            render_ascii(src)
        } else {
            render(src)
        }
        .unwrap();
        let rows = lines(&out);
        let a = center(&out, "A");
        let b = center(&out, "B");
        let actual: String = rows[3].iter().skip(a + 2).take(expected.len()).collect();
        assert_eq!(
            actual, expected,
            "complete numbered label at its origin:\n{out}"
        );
        assert!(
            a + 2 + expected.len() < b,
            "numbered label must clear intermediate lane"
        );
        assert_lanes(&out, if ascii { '#' } else { '█' }, &[(b, 3, 4)]);
        let out = if ascii {render_ascii("sequenceDiagram\nparticipant A\nautonumber 1000000000\nA->>+A: selfcall\nA-->>-A: return")} else {render("sequenceDiagram\nparticipant A\nautonumber 1000000000\nA->>+A: selfcall\nA-->>-A: return")}.unwrap();
        let a = center(&out, "A");
        let rows = lines(&out);
        for (row, label) in [(5, "[1000000000] selfcall"), (9, "[1000000001] return")] {
            let actual: String = rows[row].iter().skip(a + 3).take(label.len()).collect();
            assert_eq!(actual, label, "numbered self label must not clip:\n{out}");
            assert_eq!(
                rows[row][a + 2 + label.len().max(4) + 3],
                if ascii { '|' } else { '│' },
                "self loop right wall must survive"
            );
        }
    }
}
