//! Image artwork's place in a laid-out document.
//!
//! `image_art`'s own tests check the encoder in isolation. These check the
//! promises the *document* makes about the result: every artwork line fits the
//! width, the height bound is respected, artwork belongs to the source line its
//! reference sits on, and the colours are the fixed palette — no matter which
//! theme, encoding or page size asked for it.
//!
//! The files are the committed fixtures under `tests/fixtures/images/`, so a
//! test run needs nothing from the network or the working directory.

use md_render::document::{display_width, layout_document, source_line_count};
use md_render::image_art::{ImageEncoding, ImageOptions, PALETTE};
use md_render::renderer::render_markdown;
use md_render::theme::{Palette, Theme};
use md_render::wire::{WireDoc, WireLine};

/// The absolute, forward-slashed path of a fixture image, in the spelling a
/// markdown destination uses.
fn fixture(name: &str) -> String {
    format!(
        "{}/tests/fixtures/images/{name}",
        env!("CARGO_MANIFEST_DIR")
    )
    .replace('\\', "/")
}

fn render(content: &str, width: u16, images: ImageOptions<'_>) -> WireDoc {
    let palette = Palette::from_theme(Theme::default());
    let blocks = render_markdown(content, &palette, Theme::default());
    layout_document(&blocks, width, &palette, source_line_count(content), images)
}

/// A document whose only content is one image reference, at source line 0.
fn image_document(name: &str) -> String {
    format!("![art]({})\n", fixture(name))
}

fn line_text(line: &WireLine) -> String {
    line.spans.iter().map(|span| span.1.as_str()).collect()
}

/// The non-empty lines of a document whose only content is artwork.
fn artwork_lines(doc: &WireDoc) -> Vec<&WireLine> {
    doc.lines
        .iter()
        .filter(|line| !line.spans.is_empty())
        .collect()
}

#[test]
fn artwork_never_exceeds_the_requested_width() {
    for name in ["image_sample.png", "image_sample.jpg", "image_sample.gif"] {
        let content = image_document(name);
        for width in [20u16, 40, 80, 120] {
            let doc = render(&content, width, ImageOptions::default());
            for line in artwork_lines(&doc) {
                assert!(
                    display_width(line) <= width as usize,
                    "{name} at width {width}: artwork line is {} columns wide",
                    display_width(line)
                );
            }
        }
    }
}

#[test]
fn artwork_respects_the_height_bound() {
    let content = image_document("image_sample.png");

    for bound in [1u16, 3, 5, 8] {
        let doc = render(
            &content,
            80,
            ImageOptions {
                max_height: Some(bound),
                ..ImageOptions::default()
            },
        );
        let rows = artwork_lines(&doc).len();
        assert!(
            rows <= usize::from(bound),
            "a height bound of {bound} produced {rows} rows"
        );
        assert!(rows > 0, "a height bound of {bound} produced no artwork");
    }
}

#[test]
fn artwork_maps_back_to_the_reference_line() {
    // The reference is on source line 2, between two paragraphs.
    let content = format!("before\n\n![art]({})\n\nafter\n", fixture("image_sample.png"));
    let doc = render(&content, 80, ImageOptions::default());

    let artwork: Vec<&WireLine> = doc
        .lines
        .iter()
        .filter(|line| line_text(line).contains('\u{2580}') || line_text(line).contains('\u{2584}'))
        .collect();
    assert!(!artwork.is_empty(), "no artwork was emitted");
    for line in artwork {
        assert_eq!(
            line.source,
            Some(2),
            "artwork must anchor to the reference that produced it"
        );
    }
    // The reference's own alt text never appears beside the artwork.
    assert!(!doc.lines.iter().any(|line| line_text(line) == "art"));
}

#[test]
fn artwork_uses_only_palette_colours() {
    let allowed: Vec<String> = PALETTE.iter().map(colour_hex).collect();

    for encoding in [
        ImageEncoding::Blocks,
        ImageEncoding::Quads,
        ImageEncoding::Ascii,
    ] {
        let content = image_document("image_sample.png");
        let doc = render(
            &content,
            80,
            ImageOptions {
                encoding,
                ..ImageOptions::default()
            },
        );

        for line in artwork_lines(&doc) {
            for span in &line.spans {
                let style = &doc.styles[span.0 as usize];
                for colour in [&style.fg, &style.bg].into_iter().flatten() {
                    assert!(
                        allowed.contains(colour),
                        "{encoding:?} used {colour}, which is not one of the palette's colours"
                    );
                }
            }
        }
    }
}

#[test]
fn rendering_an_image_twice_is_byte_identical() {
    let content = image_document("image_sample.webp");
    let options = ImageOptions {
        max_height: Some(6),
        ..ImageOptions::default()
    };
    let first = serde_json::to_string(&render(&content, 60, options)).expect("serialise");
    let second = serde_json::to_string(&render(&content, 60, options)).expect("serialise");
    assert_eq!(first, second);
}

/// A palette colour in the wire format: `#rrggbb`, the same spelling
/// `wire::color_to_wire` uses for `Color::Rgb`.
fn colour_hex(colour: &md_render::style::Color) -> String {
    match colour {
        md_render::style::Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
        other => panic!("the palette must be RGB, found {other:?}"),
    }
}
