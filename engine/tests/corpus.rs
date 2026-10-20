//! The fixture corpus.
//!
//! Every file in `tests/fixtures/` is rendered, snapshotted, and checked
//! against the engine's width guarantee. The corpus is a directory rather than
//! a list so that adding a fixture is adding a file — there is no registry to
//! forget to update.
//!
//! Snapshots pin the geometry: where lines break, how a table's columns are
//! sized, what a diagram looks like, and which source line each display line
//! claims. Those are the things a change to the renderer is most likely to
//! move, and the things a reader notices first.

use md_render::block::DocBlock;
use md_render::document::{display_width, layout_document, source_line_count};
use md_render::renderer::render_markdown;
use md_render::theme::{Palette, Theme};
use md_render::wire::WireDoc;

/// The width the corpus snapshots are taken at: wide enough for a table to lay
/// out naturally, narrow enough that prose still has to wrap.
const SNAPSHOT_WIDTH: u16 = 80;

/// Widths the guarantee is checked at, from unusably narrow to generous.
const SWEEP_WIDTHS: [u16; 4] = [20, 40, 80, 120];

fn fixtures() -> Vec<(String, String)> {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures");
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap_or_else(|err| panic!("could not read the fixture directory {dir}: {err}"))
        .map(|entry| {
            entry
                .expect("a readable directory entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .filter(|name| name.ends_with(".md"))
        .collect();
    names.sort();

    assert!(!names.is_empty(), "the fixture directory is empty");

    names
        .into_iter()
        .map(|name| {
            let path = format!("{dir}/{name}");
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|err| panic!("could not read {path}: {err}"));
            (name.trim_end_matches(".md").to_string(), content)
        })
        .collect()
}

fn render(content: &str, width: u16) -> WireDoc {
    let palette = Palette::from_theme(Theme::default());
    let blocks = render_markdown(content, &palette, Theme::default());
    layout_document(&blocks, width, &palette, source_line_count(content))
}

/// A stable, readable view of a rendered document: one row per display line,
/// with its index and the source line it anchors to.
fn annotate(doc: &WireDoc) -> String {
    let mut out = format!(
        "width {}: {} lines, {} styles\n\n",
        doc.width,
        doc.lines.len(),
        doc.styles.len()
    );
    for (i, line) in doc.lines.iter().enumerate() {
        let source = match line.source {
            Some(source) => format!("{source:>3}"),
            None => "  -".to_string(),
        };
        let text: String = line.spans.iter().map(|span| span.1.as_str()).collect();
        out.push_str(&format!("{i:>3} {source} |{}\n", text.trim_end()));
    }
    out
}

#[test]
fn every_fixture_renders_to_a_snapshot() {
    let mut names: Vec<String> = Vec::new();
    for (name, content) in fixtures() {
        let doc = render(&content, SNAPSHOT_WIDTH);
        insta::assert_snapshot!(format!("{name}__rendered"), annotate(&doc));
        names.push(name);
    }
    // A snapshot name is derived from the fixture's file name, so a renamed
    // fixture leaves an orphaned snapshot behind rather than silently passing.
    assert!(!names.is_empty());
}

#[test]
fn every_fixture_renders_to_blocks_whose_anchors_are_populated() {
    let palette = Palette::from_theme(Theme::default());
    for (name, content) in fixtures() {
        let blocks = render_markdown(&content, &palette, Theme::default());
        assert!(
            !blocks.is_empty(),
            "{name} rendered to no blocks at all"
        );
        for (i, block) in blocks.iter().enumerate() {
            assert!(
                block.anchor_source_line().is_some(),
                "{name}: block {i} ({}) has no source anchor",
                block_kind(block)
            );
        }
    }
}

/// The documents the task list names explicitly, each of which must produce at
/// least one block of the expected kind.
#[test]
fn the_named_constructs_all_produce_blocks() {
    let palette = Palette::from_theme(Theme::default());
    let content = concat!(
        "# Heading\n\n",
        "- bullet\n  - nested bullet\n",
        "- [x] task\n\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n\n",
        "```rust\nlet x = 1;\n```\n\n",
        "[a link](https://example.com/)\n\n",
        "> quote\n>\n> > nested quote\n\n",
        "```mermaid\ngraph LR\n  A --> B\n```\n",
    );
    let blocks = render_markdown(content, &palette, Theme::default());

    assert!(
        blocks.iter().any(|b| matches!(b, DocBlock::Table(_))),
        "the fixture contains a table but produced no Table block"
    );
    assert!(
        blocks.iter().any(|b| matches!(b, DocBlock::Mermaid { .. })),
        "the fixture contains a mermaid fence but produced no Mermaid block"
    );
    assert!(
        blocks
            .iter()
            .any(|b| matches!(b, DocBlock::Text { .. })),
        "the fixture contains headings, lists, code and quotes but produced no Text block"
    );

    // Every line of every text block is accounted for by a source line.
    for block in &blocks {
        if let DocBlock::Text { text, source_lines } = block {
            assert_eq!(
                text.lines.len(),
                source_lines.len(),
                "a text block's lines and source anchors must be parallel"
            );
        }
    }
}

#[test]
fn no_fixture_emits_a_line_wider_than_the_requested_width() {
    for (name, content) in fixtures() {
        for width in SWEEP_WIDTHS {
            let doc = render(&content, width);
            assert_eq!(doc.width, width);
            for (i, line) in doc.lines.iter().enumerate() {
                assert!(
                    display_width(line) <= width as usize,
                    "{name} at width {width}: line {i} is {} columns wide",
                    display_width(line)
                );
            }
        }
    }
}

#[test]
fn every_fixture_is_deterministic() {
    for (name, content) in fixtures() {
        let first = serde_json::to_string(&render(&content, SNAPSHOT_WIDTH)).expect("serialise");
        let second = serde_json::to_string(&render(&content, SNAPSHOT_WIDTH)).expect("serialise");
        assert_eq!(first, second, "{name} rendered differently on a second pass");
    }
}

#[test]
fn every_fixture_has_a_total_source_map() {
    for (name, content) in fixtures() {
        let doc = render(&content, SNAPSHOT_WIDTH);
        assert_eq!(
            doc.source_map.len(),
            source_line_count(&content),
            "{name}: source_map must have one entry per source line"
        );
        for (i, &entry) in doc.source_map.iter().enumerate() {
            assert!(
                (entry as usize) < doc.lines.len(),
                "{name}: source_map[{i}] is {entry}, but there are only {} lines",
                doc.lines.len()
            );
        }
    }
}

fn block_kind(block: &DocBlock) -> &'static str {
    match block {
        DocBlock::Text { .. } => "text",
        DocBlock::Mermaid { .. } => "mermaid",
        DocBlock::Table(_) => "table",
    }
}

/// A list item's line is anchored to the item's own source line, not to the
/// nested item whose arrival flushed it.
///
/// `Tag::Item` flushes the parent's pending line when it meets the child, which
/// happens after the event loop has already stamped the child's source line. The
/// line therefore has to be carried rather than re-read. Getting this wrong
/// attributes a parent bullet to its first child, and a reader who presses `i`
/// on the parent is dropped a line down.
#[test]
fn a_parent_list_item_is_anchored_to_its_own_line() {
    let doc = render("- parent\n  - child\n- sibling\n", SNAPSHOT_WIDTH);
    let anchored: Vec<(String, Option<u32>)> = doc
        .lines
        .iter()
        .map(|line| {
            let text: String = line.spans.iter().map(|span| span.1.as_str()).collect();
            (text.trim_end().to_string(), line.source)
        })
        .collect();

    assert_eq!(
        anchored,
        vec![
            ("• parent".to_string(), Some(0)),
            ("  ◦ child".to_string(), Some(1)),
            // The nested list closes with a blank line, which inherits the line
            // of the list it belongs to.
            (String::new(), Some(1)),
            ("• sibling".to_string(), Some(2)),
            (String::new(), Some(2)),
        ],
        "the parent bullet must not inherit its child's source line"
    );
}
