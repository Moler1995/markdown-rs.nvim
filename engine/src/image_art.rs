//! Markdown images, drawn with terminal cells.
//!
//! A terminal without a graphics protocol cannot place a bitmap in a buffer.
//! What it can do is colour cells, and a cell can carry a picture the same way
//! `chafa` and `mcat` do it: one glyph per cell, coloured from the pixels it
//! covers. This module turns an image reference into those glyphs.
//!
//! # The shape of the work
//!
//! ```text
//!   destination ─▶ resolve ─▶ decode (bounded) ─▶ sample ─▶ encode ─▶ [Line]
//! ```
//!
//! * **resolve** turns what the markdown says into a path, and refuses
//!   anything that is not one.
//! * **decode** enforces the size limits *before* paying for the pixels. A
//!   document is untrusted input; a reference to a 20000×20000 PNG must cost a
//!   `stat` and a header read, not 1.6 GB.
//! * **sample** box-averages the source into a grid of terminal cells, each
//!   cell two pixels tall — that ratio is what makes a picture look like a
//!   picture instead of a tall smear.
//! * **encode** maps each sample to a glyph and colours.
//!
//! # Why a fixed palette
//!
//! The plugin defines one highlight group per distinct style it is handed, and
//! each definition redraws the editor: measured, 5,000 new groups cost 913 ms.
//! A cell names two colours, so a 64-colour palette caps the artwork at
//! 64 × 64 = 4,096 styles for every image in every document, for the whole
//! session. Quantizing per image would look better on photographs and would
//! make that cache grow without bound, which is the wrong trade for a reading
//! view of diagrams and screenshots.
//!
//! # Determinism
//!
//! Everything here is a pure function of the file's bytes and the bounds. No
//! hash map is iterated, no clock is read, and the box filter's band edges are
//! integer arithmetic — so the same document renders byte-identically, which
//! is what the wire contract promises.

use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use image::{AnimationDecoder, DynamicImage, Frame, ImageFormat, RgbImage, RgbaImage};
use serde::Serialize;

use crate::style::{Color, Line, Span, Style};

/// The largest image file, in bytes, that will be read.
///
/// Checked against `metadata` before the file is opened, so an oversized file
/// costs a `stat` rather than a read.
pub const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;

/// The largest image, in pixels, that will be decoded.
///
/// Checked against the header before the pixels are decoded. 16 megapixels is
/// 64 MiB as RGBA — a lot for a spawned process, and far more than a reading
/// view ever needs; the sampled grid is at most a few tens of thousands of
/// cells either way.
pub const MAX_PIXELS: u64 = 16_000_000;

/// The most frames an animated image may carry.
///
/// A frame costs a set of lines on the wire and a set of styles, so an image
/// with thousands of frames is not something a reading view can honour. An
/// animation with more frames is reduced to a subset of this size rather than
/// refused; the delays of the frames it stands for are folded into each kept
/// frame, so the loop keeps its total duration.
pub const MAX_ANIMATION_FRAMES: usize = 256;

/// The most frames an animation may decode before it is refused.
///
/// The frame budget above bounds what is carried, not the work: a GIF's later
/// frames are decoded as deltas, so reaching frame 4 000 still decodes 4 000
/// frames. This ceiling bounds that work independently of
/// [`MAX_ANIMATION_PIXELS`], which a file of tiny frames can stay under
/// indefinitely.
pub const MAX_DECODED_FRAMES: usize = 4_096;

/// The most decoded pixels an animation may cost, cumulatively.
///
/// [`MAX_PIXELS`] bounds one frame; a hundred 16-megapixel frames would still
/// be a hundred decodes. The frames are sampled and turned into lines as they
/// arrive, so peak memory stays at one frame — this bound is about decode CPU
/// and the size of the render request, not memory.
///
/// 128 megapixels covers a 640 × 360 GIF of 533 frames (122.8 MP) — a
/// real-world file whose first step takes about 3.5 seconds — while still
/// refusing animations that would take much longer. It is twice the previous
/// 64 MP because that bound refused the 533-frame file even though frame
/// sampling could carry it.
pub const MAX_ANIMATION_PIXELS: u64 = 128_000_000;

/// The least coverage a cell needs before it is drawn when the terminal's own
/// background is in use.
///
/// A terminal's background is not known here, so a cell that is mostly
/// transparent has to be decided rather than blended: at or above half
/// coverage the cell is ink, below it the cell shows what is behind. The
/// comparison is on the averaged alpha, not on each pixel, so an edge that
/// crosses the cell fades rather than being cut at a hard pixel boundary.
const ALPHA_COVERAGE: f32 = 0.5;

/// The most distinct image styles one document may create.
///
/// The plugin defines a highlight group per distinct fg/bg pair, so the full
/// palette needs a bound: a full-page photograph would otherwise create one
/// group per cell. 4096 is what the 64-colour palette already costs in the
/// worst case (64 × 64), so the plugin's cost profile is unchanged.
pub const MAX_IMAGE_STYLES: usize = 4096;

/// The paper braille is drawn on when the caller names none.
///
/// The default theme's background. The real caller passes the page it is
/// drawing on — the terminal's own background, in the plugin's case — but a
/// direct `artwork` call has no page to ask about, and a dark page is what a
/// terminal without a graphics protocol almost always has.
const DEFAULT_PAPER: [u8; 3] = [0x1e, 0x1e, 0x2e];

/// The amplitude of the ordered dither, in channel units.
///
/// The theme palette's levels are 85 apart, so half a step is about 42. 32
/// stays below that and still crosses the midpoint between two adjacent
/// colours, which is all an ordered dither needs; a finer adaptive palette
/// gets a slightly stronger pattern, which is the price of one fixed matrix.
const DITHER_AMPLITUDE: f32 = 32.0;

/// The Bayer 4 × 4 ordered-dither matrix, values 0–15.
///
/// Fixed and position-indexed, so the same input renders the same bytes on
/// every run. The 4 × 4 size repeats every four sub-cells, which is coarse
/// enough to read as texture rather than as per-cell noise.
const BAYER4: [[u8; 4]; 4] = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
];

/// The signed dither offset for a sub-cell at `(x, y)`, in `[-0.5, 0.5)`.
fn dither_offset(x: u32, y: u32) -> f32 {
    let value = BAYER4[(y % 4) as usize][(x % 4) as usize];
    (f32::from(value) + 0.5) / 16.0 - 0.5
}

/// `rgb` shifted by the ordered dither at `(x, y)`.
fn dithered([r, g, b]: [u8; 3], x: u32, y: u32) -> [u8; 3] {
    let offset = dither_offset(x, y) * DITHER_AMPLITUDE;
    [
        shift(r, offset),
        shift(g, offset),
        shift(b, offset),
    ]
}

/// One channel plus `offset`, clamped to 0–255.
fn shift(channel: u8, offset: f32) -> u8 {
    (f32::from(channel) + offset)
        .round()
        .clamp(0.0, 255.0) as u8
}

/// The sixty-four colours every image is drawn from.
///
/// A 4 × 4 × 4 cube over the colour channels, the levels `0x00`, `0x55`,
/// `0xaa` and `0xff`. The colours are absolute rather than taken from the
/// theme because a picture's colours are its content, not the editor's chrome
/// — the same diagram should look the same under every scheme.
///
/// The count is a compromise. A 16-colour palette cannot show a photograph at
/// all: its four dark entries are saturated, and it has no grey between black
/// and mid-grey, so a dark neutral surface becomes a speckle of navy and
/// maroon. Sixty-four gives a four-step grey ramp and enough of the colour
/// wheel to read an icon; it also keeps the highlight groups bounded at
/// 64 × 64 = 4,096 pairs, against 65,536 for the 256-colour palette.
pub const PALETTE: [Color; 64] = cube_palette();

/// The channel levels of [`PALETTE`].
const LEVELS: [u8; 4] = [0x00, 0x55, 0xaa, 0xff];

/// Build [`PALETTE`]: every combination of [`LEVELS`], red slowest.
const fn cube_palette() -> [Color; 64] {
    let mut colours = [Color::Rgb(0, 0, 0); 64];
    let mut i = 0;
    while i < 64 {
        colours[i] = Color::Rgb(LEVELS[i / 16], LEVELS[(i / 4) % 4], LEVELS[i % 4]);
        i += 1;
    }
    colours
}

/// The ASCII encoding's ramp, darkest first.
///
/// Ten levels, no shade glyphs: `░▒▓` are not ASCII, they are width-ambiguous
/// under the East Asian Width rules, and they are the glyphs that made this
/// terminal's repaints crawl. The ramp is everything the encoding promises.
pub const ASCII_RAMP: [char; 10] = ['@', '%', '#', '*', '+', '=', '-', ':', '.', ' '];

/// How an image reference is drawn.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum ImageEncoding {
    /// Braille: eight dots in a 2 × 4 grid, one colour per cell.
    #[default]
    Braille,
    /// Half blocks: upper and lower halves, one colour each.
    Blocks,
    /// Quadrants: four sub-cells in two colours, twice the horizontal detail.
    Quads,
    /// ASCII glyphs from the luminance ramp, one colour per cell.
    Ascii,
    /// No artwork; the reference reads as its alt text.
    Off,
}

/// Where a cell's colours come from.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum ImagePalette {
    /// The fixed sixty-four-colour cube, independent of the image.
    #[default]
    Theme,
    /// A sixty-four-colour palette cut from this image's own samples.
    Adaptive,
    /// The sampled colours themselves, up to [`MAX_IMAGE_STYLES`] per document.
    Full,
}

/// What lies behind partially transparent pixels.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ImageBackground {
    /// The terminal's own background: no compositing, and a cell with less
    /// than half coverage is left undrawn.
    #[default]
    Terminal,
    /// An explicit colour, used to composite partially transparent pixels.
    Rgb([u8; 3]),
}

/// How ordered dithering is chosen.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum DitherMode {
    /// On for braille, and for ASCII with a reduced palette; off elsewhere.
    Auto,
    /// Always on.
    On,
    /// Always off.
    #[default]
    Off,
}

/// The space an image may occupy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Bounds {
    /// Columns available.
    pub width: u16,
    /// Display rows available, if the caller knows the page height.
    pub height: Option<u16>,
}

/// What the caller wants done with image references.
///
/// One value rather than three arguments, because every one of them is a
/// layout input and they travel together from the command line to
/// [`crate::document::layout_document`].
#[derive(Debug, Clone, Copy, Default)]
pub struct ImageOptions<'a> {
    /// Base for relative destinations; `None` means the working directory.
    pub base: Option<&'a Path>,
    /// Height bound in display rows; `None` means width alone decides.
    pub max_height: Option<u16>,
    /// Encoding, or `Off` for alt text only.
    pub encoding: ImageEncoding,
    /// Whether to decode every frame of a GIF or animated WebP.
    ///
    /// Off by default: an ordinary render decodes the first frame only, as it
    /// always has. On, an animated image also carries its frames, which the
    /// plugin plays on request.
    pub animation: bool,
    /// Where cell colours come from.
    pub palette: ImagePalette,
    /// What partially transparent pixels are composited against.
    pub background: ImageBackground,
    /// Whether quantisation is ordered-dithered.
    pub dither: DitherMode,
    /// The fewest display rows an image is enlarged to reach, or zero.
    ///
    /// Enlargement is by the smallest whole factor from 1 to 4 that reaches
    /// the requested count and still fits the bounds, sampled with nearest
    /// neighbours so pixel art keeps its edges.
    pub min_rows: u16,
    /// Whether to apply a fixed unsharp mask to a reduced image.
    pub sharpen: bool,
    /// The colour the artwork is drawn on, for braille's ink direction.
    ///
    /// Braille has one colour and one bit per dot, so it shows a picture as
    /// ink on paper: whichever side of a sub-cell is away from the paper is
    /// what gets dots. On a dark page that is the bright side — a white
    /// document screenshot becomes a field of light dots with the text left
    /// as gaps — and on a light page it is the dark side. `None` means the
    /// caller did not say; the layout then uses the theme's background.
    pub paper: Option<[u8; 3]>,
}

/// A style reduced to the two colours that distinguish it, as 8-bit channels.
type StyleKey = (Option<[u8; 3]>, Option<[u8; 3]>);

/// The distinct image styles a document has emitted so far.
///
/// The full palette is exact only until this budget runs out; after that,
/// samples are quantised to the image's adaptive palette. Colours already
/// emitted are never changed, so reaching the cap is deterministic in
/// document order.
#[derive(Debug, Clone)]
pub struct StyleBudget {
    seen: std::collections::HashSet<StyleKey>,
    /// The seen styles in emission order, for the nearest-style fallback.
    ///
    /// A `Vec` rather than iteration over `seen`: the order is the emission
    /// order, which is what makes the fallback deterministic.
    order: Vec<StyleKey>,
    limit: usize,
}

impl Default for StyleBudget {
    fn default() -> Self {
        StyleBudget::new(MAX_IMAGE_STYLES)
    }
}

impl StyleBudget {
    /// A budget that admits `limit` distinct styles.
    #[must_use]
    pub fn new(limit: usize) -> Self {
        StyleBudget {
            seen: std::collections::HashSet::new(),
            order: Vec::new(),
            limit,
        }
    }

    /// True when no further new style may be emitted.
    fn exhausted(&self) -> bool {
        self.limit == 0 || self.seen.len() >= self.limit
    }

    /// Count `style` if it has not been seen before.
    ///
    /// Returns false only when the budget is exhausted and `style` is new, so
    /// the caller knows it must fall back to an already-counted style.
    fn note(&mut self, style: &Style) -> bool {
        let key = (style.fg.map(rgb_of), style.bg.map(rgb_of));
        if self.seen.contains(&key) {
            return true;
        }
        if self.exhausted() {
            return false;
        }
        self.seen.insert(key);
        self.order.push(key);
        true
    }

    /// The counted style closest to `style`, for use once the budget is full.
    ///
    /// Distance is squared RGB, with a large penalty when one style has a
    /// foreground (or background) and the other does not, so an unlit cell is
    /// never mapped to a coloured one.
    fn nearest(&self, style: Style) -> Style {
        let key = (style.fg.map(rgb_of), style.bg.map(rgb_of));
        let mut best: Option<(u32, StyleKey)> = None;
        for candidate in &self.order {
            let cost = channel_cost(key.0, candidate.0) + channel_cost(key.1, candidate.1);
            if best.is_none_or(|(best_cost, _)| cost < best_cost) {
                best = Some((cost, *candidate));
            }
        }
        match best {
            Some((_, (fg, bg))) => Style {
                fg: fg.map(rgb_colour),
                bg: bg.map(rgb_colour),
                modifiers: style.modifiers,
            },
            None => Style::default(),
        }
    }

    /// How many distinct styles have been emitted.
    #[must_use]
    pub fn len(&self) -> usize {
        self.seen.len()
    }

    /// True when no style has been emitted.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.seen.is_empty()
    }
}

/// One decoded frame of an animated image, drawn at the document's width.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnimationFrame {
    /// How long the frame is shown, in milliseconds, as the file records it.
    pub delay_ms: u32,
    /// The frame's display lines, in the same cell grid as the first frame.
    pub lines: Vec<Line>,
}

/// An image drawn for animation: the first frame, plus the frames the document
/// carries.
///
/// `frames` is empty for a still image, a reference that does not resolve, and
/// an animation that exceeds [`MAX_DECODED_FRAMES`] or
/// [`MAX_ANIMATION_PIXELS`]. In every one of those cases `lines` is the same
/// artwork an ordinary render produces, so the static view is unchanged. An
/// animation over [`MAX_ANIMATION_FRAMES`] is not empty: it carries a subset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Artwork {
    pub lines: Vec<Line>,
    pub frames: Vec<AnimationFrame>,
    /// True when the file *is* an animation but the caps refused it.
    ///
    /// This is what lets the plugin tell the reader that the picture they see
    /// is only its first frame because it was too large to animate, rather
    /// than leaving them to wonder why the step key does nothing. A still
    /// image, an undecodable one and an animation within the caps are all
    /// false.
    pub animation_limited: bool,
}

/// Draw `dest` as character-cell artwork at `bounds`.
///
/// `None` means "fall back to the alt text": the destination is not a local
/// file, the file is missing, the format is unsupported, a limit was exceeded,
/// or the bounds leave no room for a single cell. Every one of those is a
/// normal outcome for a document, not an error.
#[must_use]
pub fn artwork(
    dest: &str,
    bounds: Bounds,
    options: &ImageOptions,
    budget: &mut StyleBudget,
) -> Option<Vec<Line>> {
    if options.encoding == ImageEncoding::Off {
        return None;
    }
    let path = resolve(dest, options.base)?;
    let image = load(&path)?;
    let (cols, rows, enlarge) = cell_grid(image.width(), image.height(), bounds, options.min_rows)?;
    let reduced = enlarge == 1 && was_reduced(image.width(), image.height(), cols, rows);
    Some(draw(&image, cols, rows, enlarge, reduced, options, budget))
}

/// Draw `dest` and, when it animates, every one of its frames.
///
/// The static artwork is produced exactly as [`artwork`] produces it, from the
/// file's first frame. `frames` is populated only when the format is a GIF or
/// an animated WebP and the whole animation is within the caps; otherwise the
/// result is an ordinary still image. Nothing here is an error: an animation
/// that is too large renders as its first frame, which is what the static view
/// shows anyway.
#[must_use]
pub fn animated_artwork(
    dest: &str,
    bounds: Bounds,
    options: &ImageOptions,
    budget: &mut StyleBudget,
) -> Option<Artwork> {
    if options.encoding == ImageEncoding::Off {
        return None;
    }
    let path = resolve(dest, options.base)?;
    let image = load(&path)?;
    let (cols, rows, enlarge) = cell_grid(image.width(), image.height(), bounds, options.min_rows)?;
    let reduced = enlarge == 1 && was_reduced(image.width(), image.height(), cols, rows);
    let lines = draw(&image, cols, rows, enlarge, reduced, options, budget);
    let collected = collect_animation(
        &path,
        cols,
        rows,
        enlarge,
        reduced,
        options,
        image.width(),
        image.height(),
        MAX_DECODED_FRAMES,
        MAX_ANIMATION_PIXELS,
        MAX_ANIMATION_FRAMES,
        budget,
    );
    // A single-frame "animation" is a still image, and carrying it as frames
    // would make the plugin treat a PNG as animated.
    let (frames, animation_limited) = match collected {
        Collected::Frames(frames) if frames.len() > 1 => (frames, false),
        Collected::TooLarge => (Vec::new(), true),
        Collected::Frames(_) | Collected::Still => (Vec::new(), false),
    };
    Some(Artwork {
        lines,
        frames,
        animation_limited,
    })
}

/// True when drawing a `src_w` × `src_h` image at `cols` × `rows` loses detail.
fn was_reduced(src_w: u32, src_h: u32, cols: u32, rows: u32) -> bool {
    cols < src_w || rows < src_h.div_ceil(2)
}

/// Sample `image` onto the cell grid and encode it.
///
/// The sub-cell grid depends only on the encoding: braille is 2 × 4, quadrants
/// 2 × 2, and the half-block and ASCII encodings 1 × 2. Every encoding samples
/// the same source as an area average, so the encodings differ in shape and
/// colour count, not in what they look at.
#[allow(clippy::too_many_arguments)]
fn draw(
    image: &Pixels,
    cols: u32,
    rows: u32,
    enlarge: u32,
    reduced: bool,
    options: &ImageOptions,
    budget: &mut StyleBudget,
) -> Vec<Line> {
    let encoding = options.encoding;
    let (grid_cols, grid_rows) = match encoding {
        ImageEncoding::Braille => (cols * 2, rows * 4),
        ImageEncoding::Quads => (cols * 2, rows * 2),
        ImageEncoding::Blocks | ImageEncoding::Ascii => (cols, rows * 2),
        // The caller refuses `Off` before reaching here; kept so the match is
        // total.
        ImageEncoding::Off => return Vec::new(),
    };

    let mut samples = sample(image, grid_cols, grid_rows, enlarge, options.background);
    if options.sharpen && reduced {
        sharpen_samples(&mut samples, grid_cols, grid_rows);
    }

    let adaptive;
    let palette: &ColourSet = match options.palette {
        ImagePalette::Theme => theme_colours(),
        ImagePalette::Adaptive | ImagePalette::Full => {
            adaptive = ColourSet::adaptive(&samples);
            &adaptive
        }
    };

    let mut quantizer = Quantizer {
        palette,
        full: options.palette == ImagePalette::Full,
        dither: resolves_dither(options.dither, encoding, options.palette),
        budget,
    };

    match encoding {
        ImageEncoding::Braille => encode_braille(
            &samples,
            cols,
            rows,
            options.paper.unwrap_or(DEFAULT_PAPER),
            &mut quantizer,
        ),
        ImageEncoding::Blocks => encode_blocks(&samples, cols, rows, &mut quantizer),
        ImageEncoding::Quads => encode_quads(&samples, cols, rows, &mut quantizer),
        ImageEncoding::Ascii => encode_ascii(&samples, cols, rows, &mut quantizer),
        ImageEncoding::Off => Vec::new(),
    }
}

/// Whether quantisation is dithered for this encoding and palette.
fn resolves_dither(mode: DitherMode, encoding: ImageEncoding, palette: ImagePalette) -> bool {
    match mode {
        DitherMode::On => true,
        DitherMode::Off => false,
        DitherMode::Auto => match encoding {
            ImageEncoding::Braille => true,
            ImageEncoding::Ascii => palette != ImagePalette::Full,
            ImageEncoding::Blocks | ImageEncoding::Quads | ImageEncoding::Off => false,
        },
    }
}

/// True when an animation that decodes `frame_count` frames and `pixels` pixels
/// in total is within the hard animation bounds.
///
/// The carried-frame budget is not checked here: an animation over it is
/// reduced to a subset rather than refused. Both bounds are inclusive.
#[must_use]
pub fn animation_within_bounds(frame_count: usize, pixels: u64) -> bool {
    within_bounds(frame_count, pixels, MAX_DECODED_FRAMES, MAX_ANIMATION_PIXELS)
}

/// [`animation_within_bounds`] against explicit limits, so the cap can be
/// exercised with a small real animation instead of a 64-megapixel fixture.
fn within_bounds(frame_count: usize, pixels: u64, max_frames: usize, max_pixels: u64) -> bool {
    frame_count <= max_frames && pixels <= max_pixels
}

/// What [`collect_animation`] found.
enum Collected {
    /// Not a GIF or animated WebP, a still one, or a file that would not decode.
    Still,
    /// The animation exists but is past `max_decoded_frames` or `max_pixels`.
    TooLarge,
    /// The frames the document carries, in file order. Within `max_kept` this
    /// is every frame; past it, a deterministic subset.
    Frames(Vec<AnimationFrame>),
}

/// Decode every frame of `path`, or say why there are none.
///
/// Frames are decoded, sampled and encoded one at a time, so the peak bitmap
/// held is one frame. Any failure is all-or-nothing: a partially collected
/// animation is discarded by the caller, because looping back to a frame that
/// is not the file's first would misrepresent the image. [`Collected::TooLarge`]
/// is kept apart from [`Collected::Still`] so the plugin can tell the reader
/// that this picture *would* animate but was refused.
#[allow(clippy::too_many_arguments)]
fn collect_animation(
    path: &Path,
    cols: u32,
    rows: u32,
    enlarge: u32,
    reduced: bool,
    options: &ImageOptions,
    width: u32,
    height: u32,
    max_decoded_frames: usize,
    max_pixels: u64,
    max_kept: usize,
    budget: &mut StyleBudget,
) -> Collected {
    let Ok(reader) = image::ImageReader::open(path) else {
        return Collected::Still;
    };
    let Ok(reader) = reader.with_guessed_format() else {
        return Collected::Still;
    };
    let Some(format) = reader.format() else {
        return Collected::Still;
    };
    let Ok(file) = File::open(path) else {
        return Collected::Still;
    };
    let reader = BufReader::new(file);

    let frames: Box<dyn Iterator<Item = image::ImageResult<Frame>>> = match format {
        ImageFormat::Gif => {
            let Ok(decoder) = image::codecs::gif::GifDecoder::new(reader) else {
                return Collected::Still;
            };
            Box::new(decoder.into_frames())
        }
        ImageFormat::WebP => {
            let Ok(decoder) = image::codecs::webp::WebPDecoder::new(reader) else {
                return Collected::Still;
            };
            if !decoder.has_animation() {
                return Collected::Still;
            }
            Box::new(decoder.into_frames())
        }
        // APNG is not included: the design scopes animation to GIF and WebP,
        // and a format that does not expose frames here is treated as still.
        _ => return Collected::Still,
    };

    let frame_pixels = u64::from(width) * u64::from(height);
    if frame_pixels == 0 {
        return Collected::Still;
    }

    // Sampling is a streaming downsample: every frame is kept until the buffer
    // would pass `max_kept`, then every second kept frame is dropped and the
    // stride doubles. The kept frames are therefore the decoded frames whose
    // zero-based index is a multiple of the current stride, which starts at the
    // first frame, preserves file order and needs no knowledge of the total.
    // A dropped frame's display time is added to the kept frame before it, so
    // the loop runs for as long as the file says it should.
    let mut out: Vec<AnimationFrame> = Vec::new();
    let mut pixels = 0u64;
    let mut decoded = 0usize;
    let mut stride = 1usize;
    for frame in frames {
        let Ok(frame) = frame else {
            return Collected::Still;
        };
        let index = decoded;
        decoded += 1;
        let Some(total) = pixels.checked_add(frame_pixels) else {
            return Collected::TooLarge;
        };
        pixels = total;
        if !within_bounds(decoded, pixels, max_decoded_frames, max_pixels) {
            return Collected::TooLarge;
        }
        let delay = delay_ms(frame.delay());
        if !index.is_multiple_of(stride) {
            if let Some(last) = out.last_mut() {
                last.delay_ms = last.delay_ms.saturating_add(delay);
            }
            continue;
        }
        let image = Pixels::new(DynamicImage::ImageRgba8(frame.into_buffer()));
        out.push(AnimationFrame {
            delay_ms: delay,
            lines: draw(&image, cols, rows, enlarge, reduced, options, budget),
        });
        if out.len() > max_kept {
            out = halve_kept(out);
            stride *= 2;
        }
    }
    Collected::Frames(out)
}

/// Drop every second frame of `frames`, adding its delay to the kept frame
/// before it.
///
/// This is the half of the streaming downsample that acts on frames already
/// collected: dropping the odd positions leaves the even ones, which are the
/// decoded frames the doubled stride keeps, and folding the delay preserves the
/// interval each survivor stands for.
fn halve_kept(frames: Vec<AnimationFrame>) -> Vec<AnimationFrame> {
    let mut kept = Vec::with_capacity(frames.len().div_ceil(2));
    for (index, frame) in frames.into_iter().enumerate() {
        if index % 2 == 0 {
            kept.push(frame);
        } else if let Some(previous) = kept.last_mut() {
            previous.delay_ms = previous.delay_ms.saturating_add(frame.delay_ms);
        }
    }
    kept
}

/// A frame's delay in whole milliseconds.
///
/// `image` records delays as a millisecond ratio; GIFs use a denominator of
/// one, so this is exact for them. A zero denominator cannot occur (the ratio
/// is reduced on construction), but it maps to zero rather than panicking.
fn delay_ms(delay: image::Delay) -> u32 {
    let (numer, denom) = delay.numer_denom_ms();
    let half = denom / 2;
    numer.saturating_add(half) / denom.max(1)
}

/// The path `dest` names, or `None` when it does not name a local file.
///
/// Absolute destinations are used as given and relative ones against `base`.
/// `http`, `https` and `data:` are refused by scheme rather than by trying to
/// open them: a document must not be able to make the engine touch the
/// network, and a `data:` URI is not a path at all.
fn resolve(dest: &str, base: Option<&Path>) -> Option<PathBuf> {
    let trimmed = dest.trim();
    if trimmed.is_empty() {
        return None;
    }
    let scheme = trimmed.to_ascii_lowercase();
    if scheme.starts_with("http://") || scheme.starts_with("https://") || scheme.starts_with("data:")
    {
        return None;
    }

    let path = Path::new(trimmed);
    if path.is_absolute() {
        return Some(path.to_path_buf());
    }
    Some(match base {
        Some(base) => base.join(path),
        None => path.to_path_buf(),
    })
}

/// Decoded pixels, in whichever layout the decoder already produced.
///
/// The common formats land in [`Pixels::Rgb`] or [`Pixels::Rgba`] directly;
/// forcing everything through `into_rgba8` would copy the whole bitmap, which
/// measured 40 ms for a 12-megapixel JPEG — more than half the decode itself.
/// Grayscale and indexed formats still get converted, because sampling them
/// would need another two special cases for no measured gain.
enum Pixels {
    Rgb(RgbImage),
    Rgba(RgbaImage),
}

impl Pixels {
    fn new(dynamic: DynamicImage) -> Pixels {
        match dynamic {
            DynamicImage::ImageRgb8(image) => Pixels::Rgb(image),
            DynamicImage::ImageRgba8(image) => Pixels::Rgba(image),
            other => Pixels::Rgba(other.into_rgba8()),
        }
    }

    fn width(&self) -> u32 {
        match self {
            Pixels::Rgb(image) => image.width(),
            Pixels::Rgba(image) => image.width(),
        }
    }

    fn height(&self) -> u32 {
        match self {
            Pixels::Rgb(image) => image.height(),
            Pixels::Rgba(image) => image.height(),
        }
    }
}

/// Read and decode `path`, or `None` when it is too big, unreadable or not a
/// supported image.
///
/// The pixel limit is checked from the header, before `decode` allocates the
/// bitmap. The file is opened twice — once for the header, once for the
/// pixels — which is cheap next to the decode and keeps the reader's API
/// simple.
fn load(path: &Path) -> Option<Pixels> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_FILE_BYTES {
        return None;
    }

    let reader = image::ImageReader::open(path)
        .ok()?
        .with_guessed_format()
        .ok()?;
    let (width, height) = reader.into_dimensions().ok()?;
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return None;
    }

    let reader = image::ImageReader::open(path)
        .ok()?
        .with_guessed_format()
        .ok()?;
    // A GIF decodes to its first frame, which is exactly what a still reading
    // view wants.
    Some(Pixels::new(reader.decode().ok()?))
}

/// The cell grid an image of `src_w` × `src_h` occupies within `bounds`.
///
/// One source pixel is one column at natural size, and a cell is two pixels
/// tall. Both bounds apply together and the image is never enlarged beyond
/// `min_rows`: a 16-pixel icon stays 16 columns wide on an 80-column page.
/// `None` means no room for a single cell.
///
/// Returns the grid and the whole enlargement factor that was applied. The
/// factor is 1 unless `min_rows` asks for more rows than the image has at
/// natural size, and it never takes the image past the width or height bound.
fn cell_grid(
    src_w: u32,
    src_h: u32,
    bounds: Bounds,
    min_rows: u16,
) -> Option<(u32, u32, u32)> {
    if src_w == 0 || src_h == 0 || bounds.width == 0 {
        return None;
    }

    let natural_cols = f64::from(src_w);
    let natural_rows = f64::from(src_h.div_ceil(2));
    let width = f64::from(bounds.width);

    let mut enlarge = 1u32;
    if min_rows > 0 {
        // The smallest whole factor that reaches the request, capped at four;
        // if even four cannot reach it, four is still the closest.
        enlarge = 4;
        let target = f64::from(min_rows);
        for factor in 1..=4u32 {
            if natural_rows * f64::from(factor) >= target {
                enlarge = factor;
                break;
            }
        }
    }

    // An enlargement that would cross a bound is not taken at all: the image
    // keeps its natural size and is scaled down like any other.
    let fits = natural_cols * f64::from(enlarge) <= width
        && bounds
            .height
            .is_none_or(|height| natural_rows * f64::from(enlarge) <= f64::from(height));
    if !fits {
        enlarge = 1;
    }

    let base_cols = natural_cols * f64::from(enlarge);
    let base_rows = natural_rows * f64::from(enlarge);
    let mut scale = 1.0_f64.min(width / base_cols);
    if let Some(height) = bounds.height {
        if height == 0 {
            return None;
        }
        scale = scale.min(f64::from(height) / base_rows);
    }

    let cols = (base_cols * scale).round().clamp(1.0, width) as u32;
    let mut rows = (base_rows * scale).round().max(1.0) as u32;
    if let Some(height) = bounds.height {
        rows = rows.clamp(1, u32::from(height));
    }
    Some((cols, rows, enlarge))
}

/// One sub-cell's colour, averaged in linear light.
struct Average {
    /// The colour, un-premultiplied, in linear light.
    linear: [f32; 3],
    /// Mean coverage over the whole region, including transparent pixels.
    alpha: f32,
}

/// Average `image` down to a `cols` × `rows` sub-cell grid in linear light.
///
/// Each output sample covers an integer band of the source. The bands are
/// monotone and together cover every source pixel once, so the pass is linear
/// in the source and needs no floating-point edge weights. Summing in linear
/// light is what keeps a black/white edge from darkening: an sRGB average of
/// 0 and 255 is 128, while the light they actually carry averages to 188.
fn sample(
    image: &Pixels,
    cols: u32,
    rows: u32,
    enlarge: u32,
    background: ImageBackground,
) -> Vec<Option<[u8; 3]>> {
    let backdrop = match background {
        ImageBackground::Terminal => None,
        ImageBackground::Rgb(rgb) => Some(rgb.map(linearize)),
    };
    match image {
        Pixels::Rgb(image) => sample_channels::<3>(
            image.as_raw(),
            image.width(),
            image.height(),
            cols,
            rows,
            enlarge,
            backdrop,
        ),
        Pixels::Rgba(image) => sample_channels::<4>(
            image.as_raw(),
            image.width(),
            image.height(),
            cols,
            rows,
            enlarge,
            backdrop,
        ),
    }
}

/// [`sample`] over a flat buffer of `N`-byte pixels (3 = RGB, 4 = RGBA).
///
/// The channel count is a const generic so the alpha branch disappears from
/// the RGB instantiation instead of being tested twelve million times.
fn sample_channels<const N: usize>(
    buffer: &[u8],
    src_w: u32,
    src_h: u32,
    cols: u32,
    rows: u32,
    enlarge: u32,
    backdrop: Option<[f32; 3]>,
) -> Vec<Option<[u8; 3]>> {
    let stride = src_w as usize * N;
    let mut out = Vec::with_capacity((cols * rows) as usize);

    // An enlarged grid resolves each output index back to one natural
    // sub-cell; the band that sub-cell covers is one source pixel or, when a
    // bound also scaled the image down, a small region — never a blend across
    // the enlargement, which would undo it.
    let natural_cols = (cols / enlarge).max(1);
    let natural_rows = (rows / enlarge).max(1);

    for y in 0..rows {
        let natural_y = (y / enlarge).min(natural_rows - 1);
        let (y0, y1) = band(src_h, natural_rows, natural_y);
        for x in 0..cols {
            let natural_x = (x / enlarge).min(natural_cols - 1);
            let (x0, x1) = band(src_w, natural_cols, natural_x);
            out.push(
                average_region::<N>(buffer, stride, x0, x1, y0, y1)
                    .and_then(|average| resolve_sample(average, backdrop)),
            );
        }
    }

    out
}

/// The half-open source band `[start, end)` that output index `i` of `out`
/// covers, when `out` samples `src` pixels.
fn band(src: u32, out: u32, i: u32) -> (u32, u32) {
    let src = u64::from(src);
    let out = u64::from(out);
    let i = u64::from(i);

    // `out` can exceed `src` by one at an odd height, where a cell's two rows
    // straddle the last pixel. Clamping keeps every band non-empty: the final
    // row is then sampled twice, which is what "two pixels per cell" means for
    // an image with an odd number of rows.
    let start = (i * src / out).min(src - 1);
    let end = ((i + 1) * src / out).clamp(start + 1, src);
    (u32::try_from(start).unwrap_or(0), u32::try_from(end).unwrap_or(0))
}

/// The mean colour of a rectangle, if any of its pixels carry colour.
///
/// The rectangle is walked over row slices of the raw buffer rather than
/// through `get_pixel`, whose per-pixel bounds check cost about 20 ms on a
/// twelve-megapixel image.
///
/// Colours are summed in linear light and weighted by alpha, so a transparent
/// pixel contributes coverage but not darkness: half opaque red beside half
/// fully transparent pixels is red, not 50 % red. The returned colour is
/// un-premultiplied; the coverage is returned separately.
fn average_region<const N: usize>(
    buffer: &[u8],
    stride: usize,
    x0: u32,
    x1: u32,
    y0: u32,
    y1: u32,
) -> Option<Average> {
    let lut = linear_table();
    let mut sums = [0.0_f32; 3];
    let mut coverage = 0.0_f32;
    let mut count = 0u32;

    for y in y0..y1 {
        let start = y as usize * stride;
        let row = &buffer[start..start + stride];
        for x in x0..x1 {
            let i = x as usize * N;
            let alpha = if N == 4 {
                f32::from(row[i + 3]) / 255.0
            } else {
                1.0
            };
            count += 1;
            if alpha == 0.0 {
                continue;
            }
            coverage += alpha;
            sums[0] += lut[usize::from(row[i])] * alpha;
            sums[1] += lut[usize::from(row[i + 1])] * alpha;
            sums[2] += lut[usize::from(row[i + 2])] * alpha;
        }
    }

    if count == 0 || coverage == 0.0 {
        return None;
    }
    Some(Average {
        linear: [
            sums[0] / coverage,
            sums[1] / coverage,
            sums[2] / coverage,
        ],
        alpha: coverage / count as f32,
    })
}

/// Turn an averaged region into an sRGB sample, or `None` when it is too
/// transparent to draw over the terminal's own background.
fn resolve_sample(average: Average, backdrop: Option<[f32; 3]>) -> Option<[u8; 3]> {
    match backdrop {
        // No compositing without a named background: a cell that is mostly
        // transparent is left to the terminal, and one that is mostly opaque
        // keeps its own colour rather than a guess at what is behind it.
        None => (average.alpha >= ALPHA_COVERAGE)
            .then(|| average.linear.map(delinearize)),
        Some(backdrop) => {
            let alpha = average.alpha;
            Some(std::array::from_fn(|i| {
                delinearize(average.linear[i] * alpha + backdrop[i] * (1.0 - alpha))
            }))
        }
    }
}

/// The 256-entry sRGB → linear-light lookup, built once.
///
/// A `powf` per channel would be 48 million of them on a 16-megapixel image;
/// the table turns each into an array index.
fn linear_table() -> &'static [f32; 256] {
    static TABLE: OnceLock<[f32; 256]> = OnceLock::new();
    TABLE.get_or_init(|| std::array::from_fn(|i| linearize(u8::try_from(i).unwrap_or(0))))
}

/// sRGB's inverse transfer function: linear light back to an 8-bit channel.
///
/// Only samples come through here — thousands of values, not millions — so a
/// `powf` is cheaper than a second table.
fn delinearize(value: f32) -> u8 {
    let value = value.clamp(0.0, 1.0);
    let encoded = if value <= 0.003_130_8 {
        value * 12.92
    } else {
        1.055 * value.powf(1.0 / 2.4) - 0.055
    };
    (encoded * 255.0).round().clamp(0.0, 255.0) as u8
}

/// Apply a fixed 3 × 3 unsharp mask to a sampled grid.
///
/// A Gaussian blur is subtracted from the sample and the difference added
/// back, which raises the contrast of edges that area averaging softened. The
/// border is clamped, so the mask never reads outside the grid. Transparent
/// sub-cells stay transparent and are not used as neighbours: there is no
/// colour there to sharpen.
fn sharpen_samples(samples: &mut [Option<[u8; 3]>], cols: u32, rows: u32) {
    /// How much of the difference is added back.
    const AMOUNT: f32 = 0.6;

    let at = |x: u32, y: u32| samples[(y * cols + x) as usize];
    let mut out = samples.to_vec();

    for y in 0..rows {
        for x in 0..cols {
            let Some(centre) = at(x, y) else {
                continue;
            };
            let mut weight = 0.0;
            let mut blurred = [0.0_f32; 3];
            for (dy, row_weight) in [(-1i32, 1.0f32), (0, 2.0), (1, 1.0)] {
                for (dx, col_weight) in [(-1i32, 1.0f32), (0, 2.0), (1, 1.0)] {
                    let nx = (i64::from(x) + i64::from(dx)).clamp(0, i64::from(cols) - 1) as u32;
                    let ny = (i64::from(y) + i64::from(dy)).clamp(0, i64::from(rows) - 1) as u32;
                    if let Some(neighbour) = at(nx, ny) {
                        let w = row_weight * col_weight;
                        weight += w;
                        for channel in 0..3 {
                            blurred[channel] += f32::from(neighbour[channel]) * w;
                        }
                    }
                }
            }
            if weight == 0.0 {
                continue;
            }
            let sharpened = std::array::from_fn(|channel| {
                let blur = blurred[channel] / weight;
                let value = f32::from(centre[channel]);
                (value + AMOUNT * (value - blur))
                    .round()
                    .clamp(0.0, 255.0) as u8
            });
            out[(y * cols + x) as usize] = Some(sharpened);
        }
    }

    samples.copy_from_slice(&out);
}

/// A set of colours a sample may be quantised to, with their CIELAB
/// coordinates.
///
/// The theme set is the fixed cube; the adaptive set is cut from the image's
/// own samples. Both are searched the same way, so the per-cell cost does not
/// depend on which mode produced the entries.
struct ColourSet {
    colours: Vec<[u8; 3]>,
    labs: Vec<[f32; 3]>,
}

impl ColourSet {
    fn from_colours(colours: Vec<[u8; 3]>) -> ColourSet {
        let labs = colours.iter().map(|rgb| lab(*rgb)).collect();
        ColourSet { colours, labs }
    }

    /// Build a palette from the samples by median cut in CIELAB.
    ///
    /// The samples are strided to at most 4096 first, so the cost is bounded
    /// by the bound rather than by the image. The box with the largest
    /// weighted extent is split along its widest channel until 64 boxes exist;
    /// splitting a box sorts its members, and `sort_by` is stable, so equal
    /// coordinates keep their sample order and the palette is deterministic.
    fn adaptive(samples: &[Option<[u8; 3]>]) -> ColourSet {
        const MAX_SAMPLES: usize = 4096;
        const COLOURS: usize = 64;

        let present: Vec<[u8; 3]> = samples.iter().flatten().copied().collect();
        if present.is_empty() {
            return ColourSet::theme();
        }
        let stride = (present.len() / MAX_SAMPLES).max(1);
        let mut entries: Vec<([u8; 3], [f32; 3])> = present
            .iter()
            .step_by(stride)
            .take(MAX_SAMPLES)
            .map(|rgb| (*rgb, lab(*rgb)))
            .collect();

        let mut boxes = vec![(0usize, entries.len())];
        while boxes.len() < COLOURS {
            let mut chosen = None;
            let mut best_score = 0.0_f32;
            for (index, &(start, end)) in boxes.iter().enumerate() {
                if end - start < 2 {
                    continue;
                }
                let Some((extent, channel)) = widest_channel(&entries[start..end]) else {
                    continue;
                };
                // Weighted by population: a large box with a small extent is
                // still where most of the image's error lives.
                let score = extent * (end - start) as f32;
                if score > best_score {
                    best_score = score;
                    chosen = Some((index, channel));
                }
            }
            let Some((index, channel)) = chosen else {
                break;
            };

            let (start, end) = boxes[index];
            entries[start..end].sort_by(|a, b| {
                a.1[channel]
                    .partial_cmp(&b.1[channel])
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let middle = start + (end - start) / 2;
            boxes[index] = (start, middle);
            boxes.push((middle, end));
        }

        let colours = boxes
            .iter()
            .map(|&(start, end)| mean_rgb(&entries[start..end]))
            .collect();
        ColourSet::from_colours(colours)
    }

    fn theme() -> ColourSet {
        ColourSet::from_colours(PALETTE.iter().map(|colour| rgb_of(*colour)).collect())
    }

    /// The index of the colour closest to `rgb`, measured in CIELAB.
    ///
    /// Distance is taken in CIELAB rather than in RGB because RGB distance is
    /// channel-wise, and channel-wise distance cannot tell a neutral colour
    /// from a saturated one that happens to sit at the same point per channel.
    /// Measured on a desktop screenshot, plain RGB sent the dark grey rock of
    /// a wallpaper to navy: at (74, 79, 85) the rock's blue channel is nearer
    /// 128 than 0, so `#000080` beat both `#000000` and `#808080`. CIELAB
    /// compares lightness and hue separately and sends the same grey to
    /// `#808080`.
    fn nearest_index(&self, rgb: [u8; 3]) -> usize {
        let target = lab(rgb);
        let mut best = 0;
        let mut best_distance = f32::MAX;

        for (index, entry) in self.labs.iter().enumerate() {
            let distance = squared_distance(&target, entry);
            if distance < best_distance {
                best_distance = distance;
                best = index;
            }
        }

        best
    }

    fn nearest(&self, rgb: [u8; 3]) -> Color {
        let [r, g, b] = self.colours[self.nearest_index(rgb)];
        Color::Rgb(r, g, b)
    }
}

/// The theme palette's [`ColourSet`], built once for the life of the process.
fn theme_colours() -> &'static ColourSet {
    static SET: OnceLock<ColourSet> = OnceLock::new();
    SET.get_or_init(ColourSet::theme)
}

/// The theme palette colour closest to `rgb`, measured in CIELAB.
#[cfg(test)]
fn nearest_palette(rgb: [u8; 3]) -> Color {
    theme_colours().nearest(rgb)
}

/// The extent and widest channel of a box of samples, or `None` when every
/// member sits at the same point.
fn widest_channel(entries: &[([u8; 3], [f32; 3])]) -> Option<(f32, usize)> {
    let mut low = [f32::MAX; 3];
    let mut high = [f32::NEG_INFINITY; 3];
    for &(_, lab) in entries {
        for channel in 0..3 {
            low[channel] = low[channel].min(lab[channel]);
            high[channel] = high[channel].max(lab[channel]);
        }
    }

    let mut widest = None;
    let mut widest_extent = 0.0;
    for channel in 0..3 {
        let extent = high[channel] - low[channel];
        if extent > widest_extent {
            widest_extent = extent;
            widest = Some((extent, channel));
        }
    }
    widest
}

/// The mean sRGB colour of a non-empty box.
fn mean_rgb(entries: &[([u8; 3], [f32; 3])]) -> [u8; 3] {
    let mut sums = [0u32; 3];
    for (rgb, _) in entries {
        for channel in 0..3 {
            sums[channel] += u32::from(rgb[channel]);
        }
    }
    let count = u32::try_from(entries.len()).unwrap_or(1).max(1);
    [
        u8::try_from(sums[0] / count).unwrap_or(0),
        u8::try_from(sums[1] / count).unwrap_or(0),
        u8::try_from(sums[2] / count).unwrap_or(0),
    ]
}

/// Squared distance between two CIELAB colours.
fn squared_distance(a: &[f32; 3], b: &[f32; 3]) -> f32 {
    (0..3).map(|i| (a[i] - b[i]).powi(2)).sum()
}

/// The colour decision for one image: which palette, whether to dither, and
/// how much of the document's style budget is left.
struct Quantizer<'a> {
    palette: &'a ColourSet,
    /// True in `full` mode, where samples are emitted exactly until the
    /// budget runs out.
    full: bool,
    dither: bool,
    budget: &'a mut StyleBudget,
}

impl Quantizer<'_> {
    /// The colour to emit for a sample at `(x, y)`.
    fn colour(&self, rgb: [u8; 3], x: u32, y: u32) -> Color {
        if self.full && !self.budget.exhausted() {
            let [r, g, b] = rgb;
            return Color::Rgb(r, g, b);
        }
        let rgb = if self.dither {
            dithered(rgb, x, y)
        } else {
            rgb
        };
        self.palette.nearest(rgb)
    }

    /// The palette index a sample maps to, after dithering.
    ///
    /// [`quad_cell`] works with indices rather than colours because it scores
    /// fourteen candidate splits per cell, and the palette's CIELAB
    /// coordinates are already computed: returning the index keeps the Lab
    /// conversion to the one target colour instead of converting every
    /// candidate back.
    fn index(&self, rgb: [u8; 3], x: u32, y: u32) -> usize {
        let rgb = if self.dither {
            dithered(rgb, x, y)
        } else {
            rgb
        };
        self.palette.nearest_index(rgb)
    }

    /// True when the next cell may still be drawn with exact colours.
    fn exact(&self) -> bool {
        self.full && !self.budget.exhausted()
    }

    /// Count a cell's style against the document's budget.
    ///
    /// Once the budget is full, a style that has not been seen is replaced by
    /// the counted style closest to it, so the document never exceeds the cap.
    fn note(&mut self, style: Style) -> Style {
        if style == Style::default() {
            return style;
        }
        if self.budget.note(&style) {
            style
        } else {
            self.budget.nearest(style)
        }
    }
}

/// The CIELAB (D65) coordinates of an sRGB colour.
fn lab([r, g, b]: [u8; 3]) -> [f32; 3] {
    let (r, g, b) = (linearize(r), linearize(g), linearize(b));

    // sRGB → XYZ, D65.
    let x = 0.412_456_4 * r + 0.357_576_1 * g + 0.180_437_5 * b;
    let y = 0.212_672_9 * r + 0.715_152_2 * g + 0.072_175_0 * b;
    let z = 0.019_333_9 * r + 0.119_192 * g + 0.950_304_1 * b;

    let (fx, fy, fz) = (lab_f(x / 0.950_47), lab_f(y), lab_f(z / 1.088_83));
    [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
}

/// CIELAB's companding curve for one XYZ component, relative to the white point.
fn lab_f(ratio: f32) -> f32 {
    const DELTA: f32 = 6.0 / 29.0;
    if ratio > DELTA * DELTA * DELTA {
        ratio.cbrt()
    } else {
        ratio / (3.0 * DELTA * DELTA) + 4.0 / 29.0
    }
}

/// sRGB's transfer function: an 8-bit channel as linear light.
fn linearize(channel: u8) -> f32 {
    let value = f32::from(channel) / 255.0;
    if value <= 0.040_45 {
        value / 12.92
    } else {
        ((value + 0.055) / 1.055).powf(2.4)
    }
}

/// The components of a palette colour.
fn rgb_of(colour: Color) -> [u8; 3] {
    match colour {
        Color::Rgb(r, g, b) => [r, g, b],
        _ => [0, 0, 0],
    }
}

/// Luminance on the usual 0–255 scale.
fn luminance([r, g, b]: [u8; 3]) -> f32 {
    0.2126 * f32::from(r) + 0.7152 * f32::from(g) + 0.0722 * f32::from(b)
}

/// The style for one half-block cell.
///
/// `▀` covers the upper half with its foreground and the lower half with its
/// background, so a cell with only a visible lower half uses `▄` instead — a
/// `▀` with no background would paint the terminal's *foreground* over the
/// half that should be empty, not leave it alone.
fn half_block(upper: Option<Color>, lower: Option<Color>) -> (char, Style) {
    match (upper, lower) {
        (Some(upper), Some(lower)) => (
            '\u{2580}',
            Style::default().fg(upper).bg(lower),
        ),
        (Some(upper), None) => ('\u{2580}', Style::default().fg(upper)),
        (None, Some(lower)) => ('\u{2584}', Style::default().fg(lower)),
        (None, None) => (' ', Style::default()),
    }
}

/// One cell's ASCII glyph and its colour.
fn ascii_cell(
    upper: Option<[u8; 3]>,
    lower: Option<[u8; 3]>,
    quantizer: &Quantizer,
    x: u32,
    y: u32,
) -> (char, Style) {
    let rgb = match (upper, lower) {
        (None, None) => return (' ', Style::default()),
        (Some(only), None) | (None, Some(only)) => only,
        (Some(a), Some(b)) => [a, b]
            .iter()
            .fold([0u32; 3], |mut sums, rgb| {
                for channel in 0..3 {
                    sums[channel] += u32::from(rgb[channel]);
                }
                sums
            })
            .map(|sum| u8::try_from(sum / 2).unwrap_or(0)),
    };
    let colour = quantizer.colour(rgb, x, y);

    // The ramp is ordered darkest first, so a dark sample takes the first (most
    // inked) glyph and a light one fades towards a space.
    let level = luminance(rgb_of(colour)) / 255.0 * (ASCII_RAMP.len() - 1) as f32;
    let index = (level.round() as usize).min(ASCII_RAMP.len() - 1);
    (ASCII_RAMP[index], Style::default().fg(colour))
}

/// Append `(glyph, style)` to `line`, merging it into the previous span when
/// both match.
fn push_cell(line: &mut Line, glyph: char, style: Style) {
    match line.spans.last_mut() {
        Some(span) if span.style == style => span.content.push(glyph),
        _ => line.spans.push(Span::styled(glyph.to_string(), style)),
    }
}

/// Draw the sampled grid with half blocks.
fn encode_blocks(
    samples: &[Option<[u8; 3]>],
    cols: u32,
    rows: u32,
    quantizer: &mut Quantizer,
) -> Vec<Line> {
    let mut lines = Vec::with_capacity(rows as usize);

    for row in 0..rows {
        let mut line = Line::new();
        for col in 0..cols {
            let upper_y = row * 2;
            let lower_y = upper_y + 1;
            let upper = samples[(upper_y * cols + col) as usize]
                .map(|rgb| quantizer.colour(rgb, col, upper_y));
            let lower = samples[(lower_y * cols + col) as usize]
                .map(|rgb| quantizer.colour(rgb, col, lower_y));
            let (glyph, style) = half_block(upper, lower);
            let style = quantizer.note(style);
            push_cell(&mut line, glyph, style);
        }
        lines.push(line);
    }

    lines
}

/// The sixteen quadrant masks, indexed by which quadrants are foreground.
///
/// Bit 0 is upper left, bit 1 upper right, bit 2 lower left, bit 3 lower right.
/// Every mask has a glyph in Block Elements (U+2580–U+259F), which Cascadia
/// Mono and the other monospace fonts that ship with editors cover.
const QUADRANTS: [char; 16] = [
    ' ',        // 0000
    '\u{2598}', // 0001 upper left
    '\u{259d}', // 0010 upper right
    '\u{2580}', // 0011 upper half
    '\u{2596}', // 0100 lower left
    '\u{258c}', // 0101 left half
    '\u{259e}', // 0110 upper right and lower left
    '\u{259b}', // 0111 all but lower right
    '\u{2597}', // 1000 lower right
    '\u{259a}', // 1001 upper left and lower right
    '\u{2590}', // 1010 right half
    '\u{259c}', // 1011 all but lower left
    '\u{2584}', // 1100 lower half
    '\u{2599}', // 1101 all but upper right
    '\u{259f}', // 1110 all but upper left
    '\u{2588}', // 1111 full
];

/// The masks that name every unordered split of four quadrants once.
///
/// The upper-left quadrant is always in the foreground: swapping the two
/// colours and inverting the glyph draws the same cell, so each pair of
/// colours needs to be tried once.
const PARTITIONS: [u8; 7] = [1, 3, 5, 7, 9, 11, 13];

/// Draw the sampled grid with quadrants.
///
/// The grid is `2·cols` wide and `2·rows` tall, four samples to a cell, and
/// each cell names at most two colours.
fn encode_quads(
    samples: &[Option<[u8; 3]>],
    cols: u32,
    rows: u32,
    quantizer: &mut Quantizer,
) -> Vec<Line> {
    let stride = cols as usize * 2;
    let mut lines = Vec::with_capacity(rows as usize);

    for row in 0..rows {
        let mut line = Line::new();
        for col in 0..cols {
            let x = col as usize * 2;
            let y = row as usize * 2;
            let quadrants = [
                samples[y * stride + x],
                samples[y * stride + x + 1],
                samples[(y + 1) * stride + x],
                samples[(y + 1) * stride + x + 1],
            ];
            let (glyph, style) = quad_cell(quadrants, quantizer, col * 2, row * 2);
            let style = quantizer.note(style);
            push_cell(&mut line, glyph, style);
        }
        lines.push(line);
    }

    lines
}

/// One cell's quadrant glyph and style.
///
/// A cell that is not fully opaque is drawn in a single colour: a background
/// colour fills the whole cell, so it would paint over the quadrant that is
/// supposed to show the terminal's background. A fully opaque cell takes the
/// two-colour split that fits its four samples best.
fn quad_cell(
    quadrants: [Option<[u8; 3]>; 4],
    quantizer: &Quantizer,
    x: u32,
    y: u32,
) -> (char, Style) {
    let mut mask = 0u8;
    let mut present = [[0u8; 3]; 4];
    let mut count = 0;

    for (i, quadrant) in quadrants.iter().enumerate() {
        if let Some(rgb) = *quadrant {
            mask |= 1u8 << i;
            present[count] = rgb;
            count += 1;
        }
    }

    if count == 0 {
        return (' ', Style::default());
    }
    if count < 4 {
        let colour = quantizer.colour(mean(&present[..count]), x, y);
        return (QUADRANTS[usize::from(mask)], Style::default().fg(colour));
    }

    let labs = present.map(lab);
    let mut best = (f32::MAX, 0u8, [0u8; 3], [0u8; 3]);

    if quantizer.exact() {
        // Exact colours: each partition is scored against the true mean of
        // its own side, so the split follows the image rather than the cube.
        for &partition in &PARTITIONS {
            let (fg, bg) = partition_means(&present, partition);
            let (fg_lab, bg_lab) = (lab(fg), lab(bg));
            let cost = partition_cost(&labs, partition, &fg_lab, &bg_lab);
            if cost < best.0 {
                best = (cost, partition, fg, bg);
            }
        }
    } else {
        for &partition in &PARTITIONS {
            let (fg, bg) = partition_means(&present, partition);
            let fg_index = quantizer.index(fg, x, y);
            let bg_index = quantizer.index(bg, x, y);
            let (fg_lab, bg_lab) = (
                &quantizer.palette.labs[fg_index],
                &quantizer.palette.labs[bg_index],
            );
            let cost = partition_cost(&labs, partition, fg_lab, bg_lab);
            if cost < best.0 {
                best = (
                    cost,
                    partition,
                    quantizer.palette.colours[fg_index],
                    quantizer.palette.colours[bg_index],
                );
            }
        }
    }

    let (_, partition, fg, bg) = best;
    if fg == bg {
        let [r, g, b] = fg;
        return ('\u{2588}', Style::default().fg(Color::Rgb(r, g, b)));
    }
    let (fg, bg) = (rgb_colour(fg), rgb_colour(bg));
    (
        QUADRANTS[usize::from(partition)],
        Style::default().fg(fg).bg(bg),
    )
}

/// The mean colour of each side of a quadrant partition.
fn partition_means(present: &[[u8; 3]; 4], partition: u8) -> ([u8; 3], [u8; 3]) {
    let mut sums = [[0u32; 3]; 2];
    let mut counts = [0u32; 2];
    for (i, rgb) in present.iter().enumerate() {
        let side = usize::from(partition >> i & 1 == 0);
        for channel in 0..3 {
            sums[side][channel] += u32::from(rgb[channel]);
        }
        counts[side] += 1;
    }
    (
        average(sums[0], counts[0]),
        average(sums[1], counts[1]),
    )
}

/// How badly `partition`'s two colours explain the four samples.
fn partition_cost(
    labs: &[[f32; 3]; 4],
    partition: u8,
    fg_lab: &[f32; 3],
    bg_lab: &[f32; 3],
) -> f32 {
    (0..4)
        .map(|i| {
            let target = if partition >> i & 1 == 1 {
                fg_lab
            } else {
                bg_lab
            };
            squared_distance(&labs[i], target)
        })
        .sum()
}

/// The mean of a non-empty slice of colours.
fn mean(colours: &[[u8; 3]]) -> [u8; 3] {
    let mut sums = [0u32; 3];
    for rgb in colours {
        for channel in 0..3 {
            sums[channel] += u32::from(rgb[channel]);
        }
    }
    average(sums, u32::try_from(colours.len()).unwrap_or(1))
}

/// `sum / count` per channel, as an RGB triple. `count` is never zero.
fn average(sums: [u32; 3], count: u32) -> [u8; 3] {
    [
        u8::try_from(sums[0] / count).unwrap_or(0),
        u8::try_from(sums[1] / count).unwrap_or(0),
        u8::try_from(sums[2] / count).unwrap_or(0),
    ]
}

/// An RGB triple as a [`Color`].
fn rgb_colour([r, g, b]: [u8; 3]) -> Color {
    Color::Rgb(r, g, b)
}

/// Squared RGB distance between two optional channels.
///
/// A present and an absent channel are farther apart than any two colours, so
/// a lit cell is never mapped onto an unlit one.
fn channel_cost(a: Option<[u8; 3]>, b: Option<[u8; 3]>) -> u32 {
    match (a, b) {
        (Some(a), Some(b)) => (0..3)
            .map(|i| {
                let delta = u32::from(a[i].abs_diff(b[i]));
                delta * delta
            })
            .sum(),
        (None, None) => 0,
        _ => 1_000_000,
    }
}

/// Draw the sampled grid with the ASCII ramp.
fn encode_ascii(
    samples: &[Option<[u8; 3]>],
    cols: u32,
    rows: u32,
    quantizer: &mut Quantizer,
) -> Vec<Line> {
    let mut lines = Vec::with_capacity(rows as usize);

    for row in 0..rows {
        let mut line = Line::new();
        for col in 0..cols {
            let upper_y = row * 2;
            let lower_y = upper_y + 1;
            let (glyph, style) = ascii_cell(
                samples[(upper_y * cols + col) as usize],
                samples[(lower_y * cols + col) as usize],
                quantizer,
                col,
                upper_y,
            );
            let style = quantizer.note(style);
            push_cell(&mut line, glyph, style);
        }
        lines.push(line);
    }

    lines
}

/// The bit each dot contributes, indexed `[row][column]`.
///
/// The standard braille numbering: dots 1–3 and 7 down the left column, 4–6
/// and 8 down the right. U+2800 plus these bits is the glyph.
const BRAILLE_BITS: [[u8; 2]; 4] = [
    [0x01, 0x08],
    [0x02, 0x10],
    [0x04, 0x20],
    [0x40, 0x80],
];

/// Draw the sampled grid as braille dot patterns.
///
/// The grid is `2·cols` wide and `4·rows` tall, eight sub-cells to a cell. A
/// dot is lit when its sub-cell is darker than the cell as a whole. A cell
/// with no internal contrast has no such sub-cell, so its tone is taken from
/// the midpoint instead: a uniform dark cell is solid ink, a uniform light
/// one is blank, and the ordered dither fills the middle of that range with a
/// pattern rather than a hard edge. The ink is the mean of the lit sub-cells,
/// and there is never a background colour, so transparent sub-cells stay
/// transparent.
fn encode_braille(
    samples: &[Option<[u8; 3]>],
    cols: u32,
    rows: u32,
    paper: [u8; 3],
    quantizer: &mut Quantizer,
) -> Vec<Line> {
    let stride = cols as usize * 2;
    let mut lines = Vec::with_capacity(rows as usize);

    for row in 0..rows {
        let mut line = Line::new();
        for col in 0..cols {
            let x = col as usize * 2;
            let y = row as usize * 4;
            let sub_cells = [
                samples[y * stride + x],
                samples[y * stride + x + 1],
                samples[(y + 1) * stride + x],
                samples[(y + 1) * stride + x + 1],
                samples[(y + 2) * stride + x],
                samples[(y + 2) * stride + x + 1],
                samples[(y + 3) * stride + x],
                samples[(y + 3) * stride + x + 1],
            ];
            let (glyph, style) = braille_cell(sub_cells, quantizer, paper, col * 2, row * 4);
            let style = quantizer.note(style);
            push_cell(&mut line, glyph, style);
        }
        lines.push(line);
    }

    lines
}

/// One cell's braille glyph and style.
///
/// A braille cell is eight dots of one colour, so a picture is drawn the way
/// ink is laid on paper: a dot is lit when its sub-cell is far enough from the
/// paper, on whichever side the paper is not. On a dark page the bright side
/// carries the ink — a white screenshot of a document becomes a field of light
/// dots with its text left as gaps — and on a light page the dark side does.
/// Comparing against the *cell's own* mean instead lights about half the dots
/// of every cell with contrast, which is a texture rather than a picture, and
/// on a dark page it inks nothing but the shadows.
///
/// The threshold walks from the paper to the far end of the range with the
/// ordered dither, so the fraction of lit dots follows a sub-cell's distance
/// from the paper. That density is the only tone one bit per dot can carry.
fn braille_cell(
    sub_cells: [Option<[u8; 3]>; 8],
    quantizer: &Quantizer,
    paper: [u8; 3],
    x: u32,
    y: u32,
) -> (char, Style) {
    // Distance is per channel, not by luminance: pure red has the luminance of
    // a mid grey and pure blue of a near-black, and a luminance test would drop
    // both into the page and leave a coloured logo with nothing but its white
    // surroundings. Any channel away from the paper is ink.
    let dark_paper = luminance(paper) < 128.0;
    let span = if dark_paper {
        255 - paper.iter().copied().min().unwrap_or(0)
    } else {
        paper.iter().copied().max().unwrap_or(255)
    };
    let span = f32::from(span);

    let mut bits = 0u8;
    let mut ink = [0u32; 3];
    let mut lit = 0u32;
    for (index, rgb) in sub_cells.iter().enumerate() {
        let Some(rgb) = *rgb else {
            continue;
        };
        // The dither's position in the matrix as 0–1, so the threshold covers
        // the whole range between the paper and the far end.
        let step = if quantizer.dither {
            dither_offset(x + index as u32 % 2, y + (index / 2) as u32) + 0.5
        } else {
            0.5
        };
        let distance = if dark_paper {
            rgb.iter()
                .zip(paper.iter())
                .map(|(&channel, &behind)| i32::from(channel) - i32::from(behind))
                .max()
                .unwrap_or(0)
        } else {
            rgb.iter()
                .zip(paper.iter())
                .map(|(&channel, &behind)| i32::from(behind) - i32::from(channel))
                .max()
                .unwrap_or(0)
        };
        let is_ink = distance > (step * span) as i32;
        if is_ink {
            bits |= BRAILLE_BITS[index / 2][index % 2];
            for channel in 0..3 {
                ink[channel] += u32::from(rgb[channel]);
            }
            lit += 1;
        }
    }

    if bits == 0 {
        return ('\u{2800}', Style::default());
    }

    let colour = quantizer.colour(average(ink, lit), x, y);
    (
        char::from_u32(0x2800 + u32::from(bits)).unwrap_or('\u{2800}'),
        Style::default().fg(colour),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/images")
            .join(name)
    }

    fn image(width: u32, height: u32, pixels: &[[u8; 4]]) -> RgbaImage {
        RgbaImage::from_fn(width, height, |x, y| {
            let p = pixels[(y * width + x) as usize];
            image::Rgba(p)
        })
    }

    // ── Resolution ─────────────────────────────────────────────────────────

    #[test]
    fn absolute_destinations_are_used_as_given() {
        let resolved = resolve("C:/docs/a.png", Some(Path::new("C:/other")));
        assert_eq!(resolved, Some(PathBuf::from("C:/docs/a.png")));
    }

    #[test]
    fn relative_destinations_resolve_against_the_base() {
        let resolved = resolve("img/a.png", Some(Path::new("C:/docs")));
        assert_eq!(resolved, Some(PathBuf::from("C:/docs").join("img/a.png")));
    }

    #[test]
    fn relative_destinations_without_a_base_stay_relative() {
        let resolved = resolve("img/a.png", None);
        assert_eq!(resolved, Some(PathBuf::from("img/a.png")));
    }

    #[test]
    fn remote_and_data_destinations_are_refused() {
        assert_eq!(resolve("http://example.com/a.png", None), None);
        assert_eq!(resolve("HTTPS://example.com/a.png", None), None);
        assert_eq!(resolve("data:image/png;base64,AAAA", None), None);
        assert_eq!(resolve("", None), None);
    }

    // ── Loading and limits ─────────────────────────────────────────────────

    #[test]
    fn every_supported_format_decodes() {
        for name in [
            "image_sample.png",
            "image_sample.jpg",
            "image_sample.gif",
            "image_sample.bmp",
            "image_sample.tiff",
            "image_sample.webp",
            "image_sample.ico",
        ] {
            let loaded = load(&fixture(name))
                .unwrap_or_else(|| panic!("{name} should decode as a supported format"));
            assert_eq!((loaded.width(), loaded.height()), (16, 16), "{name}");
        }
    }

    #[test]
    fn a_corrupt_file_does_not_decode() {
        assert!(load(&fixture("image_corrupt.png")).is_none());
    }

    #[test]
    fn a_missing_file_does_not_decode() {
        assert!(load(&fixture("image_missing.png")).is_none());
    }

    #[test]
    fn an_oversized_file_is_refused_before_its_dimensions_are_read() {
        // A file over the limit whose *contents* are a valid 4x2 PNG: if the
        // size check ran second, this would decode.
        let dir = std::env::temp_dir().join("md-render-image-limit-test");
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("oversized.png");
        let mut bytes = std::fs::read(fixture("image_cells.png")).expect("fixture");
        bytes.resize(usize::try_from(MAX_FILE_BYTES).expect("fits") + 1, 0);
        std::fs::write(&path, &bytes).expect("write");

        assert!(load(&path).is_none());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn an_oversized_pixel_count_is_refused_from_the_header() {
        // The header says 5000x4000 = 20 megapixels, over the 16 MP limit; the
        // body is never decoded. The file is a real PNG of that size written
        // to a temp path, so the header is genuine.
        let dir = std::env::temp_dir().join("md-render-pixel-limit-test");
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("huge.png");
        let img = RgbaImage::from_pixel(5000, 4000, image::Rgba([1, 2, 3, 255]));
        img.save(&path).expect("write a large PNG");

        assert!(load(&path).is_none());
        let _ = std::fs::remove_file(&path);
    }

    // ── Bounds ─────────────────────────────────────────────────────────────

    #[test]
    fn a_wide_image_is_scaled_to_the_width() {
        assert_eq!(
            cell_grid(1200, 600, Bounds { width: 80, height: None }, 0),
            Some((80, 20, 1))
        );
    }

    #[test]
    fn a_narrow_image_is_not_enlarged_by_default() {
        assert_eq!(
            cell_grid(16, 8, Bounds { width: 80, height: None }, 0),
            Some((16, 4, 1))
        );
    }

    #[test]
    fn the_height_bound_binds_first() {
        // 400x2000 at width 80 would be 100 rows; the page has 40.
        let (cols, rows, _) =
            cell_grid(400, 2000, Bounds { width: 80, height: Some(40) }, 0).unwrap();
        assert_eq!(rows, 40);
        assert!(cols <= 80);
        // The aspect ratio survives: cols/rows ≈ 2 * 400/2000.
        assert!((f64::from(cols) / f64::from(rows) - 0.4).abs() < 0.1);
    }

    #[test]
    fn a_short_image_keeps_its_natural_height_on_a_tall_page() {
        assert_eq!(
            cell_grid(20, 10, Bounds { width: 80, height: Some(40) }, 0),
            Some((20, 5, 1))
        );
    }

    #[test]
    fn no_room_for_a_cell_is_a_fallback() {
        assert_eq!(cell_grid(10, 10, Bounds { width: 0, height: None }, 0), None);
        assert_eq!(
            cell_grid(10, 10, Bounds { width: 80, height: Some(0) }, 0),
            None
        );
        assert_eq!(cell_grid(0, 10, Bounds { width: 80, height: None }, 0), None);
        assert_eq!(cell_grid(10, 0, Bounds { width: 80, height: None }, 0), None);
    }

    #[test]
    fn a_minimum_height_enlarges_by_the_smallest_whole_factor() {
        // 16x16 is 8 natural rows; a minimum of 10 takes factor 2 (16 rows).
        assert_eq!(
            cell_grid(16, 16, Bounds { width: 80, height: None }, 10),
            Some((32, 16, 2))
        );
        // A minimum already met changes nothing.
        assert_eq!(
            cell_grid(16, 16, Bounds { width: 80, height: None }, 8),
            Some((16, 8, 1))
        );
        // 16 rows at factor 2 would cross the height bound, so it is not taken.
        assert_eq!(
            cell_grid(16, 16, Bounds { width: 80, height: Some(8) }, 10),
            Some((16, 8, 1))
        );
    }

    // ── Sampling ───────────────────────────────────────────────────────────

    /// One sub-cell grid of `cols` × `rows` samples over `img`.
    fn sample_grid(img: RgbaImage, cols: u32, rows: u32, background: ImageBackground) -> Vec<Option<[u8; 3]>> {
        sample(&Pixels::Rgba(img), cols, rows, 1, background)
    }

    #[test]
    fn a_flat_region_averages_to_its_own_colour() {
        let img = image(2, 2, &[[255, 0, 0, 255]; 4]);
        let samples = sample_grid(img, 1, 2, ImageBackground::Terminal);
        assert_eq!(samples, [Some([255, 0, 0]), Some([255, 0, 0])]);
    }

    #[test]
    fn a_transparent_region_samples_as_none() {
        let img = image(2, 2, &[[255, 0, 0, 0]; 4]);
        let samples = sample_grid(img, 1, 2, ImageBackground::Terminal);
        assert_eq!(samples, [None, None]);
    }

    #[test]
    fn a_half_transparent_region_averages_only_its_opaque_pixels() {
        // Two pixels: one red and opaque, one green and transparent. The
        // average must be red, not a blend with the transparent pixel.
        let img = image(2, 2, &[
            [255, 0, 0, 255],
            [0, 255, 0, 0],
            [255, 0, 0, 255],
            [0, 255, 0, 0],
        ]);
        let samples = sample_grid(img, 1, 2, ImageBackground::Terminal);
        assert_eq!(samples, [Some([255, 0, 0]), Some([255, 0, 0])]);
    }

    #[test]
    fn a_black_and_white_average_is_the_light_midpoint_not_128() {
        // Half black, half white. Averaged as sRGB bytes this is 128; the
        // light the two pixels carry averages to 188 in sRGB.
        let img = image(2, 1, &[[0, 0, 0, 255], [255, 255, 255, 255]]);
        let samples = sample_grid(img, 1, 1, ImageBackground::Terminal);
        let [r, g, b] = samples[0].expect("the pair is opaque");
        assert_eq!((r, g, b), (188, 188, 188), "linear-light midpoint");
    }

    #[test]
    fn a_uniform_image_round_trips_through_linear_light() {
        for level in [0_u8, 1, 42, 128, 200, 254, 255] {
            let img = image(2, 1, &[[level, level, level, 255]; 2]);
            let samples = sample_grid(img, 1, 1, ImageBackground::Terminal);
            assert_eq!(samples[0], Some([level, level, level]), "level {level}");
        }
    }

    #[test]
    fn a_half_alpha_pixel_composites_against_a_named_background() {
        // White at 50 % over black: 0.5 in linear light, which is 188 in sRGB.
        let img = image(1, 1, &[[255, 255, 255, 128]]);
        let samples = sample_grid(img, 1, 1, ImageBackground::Rgb([0, 0, 0]));
        assert_eq!(samples[0], Some([188, 188, 188]));
    }

    #[test]
    fn the_terminal_background_does_not_composite() {
        // White at 50 % over the terminal: the colour is white, not grey.
        let img = image(1, 1, &[[255, 255, 255, 128]]);
        let samples = sample_grid(img, 1, 1, ImageBackground::Terminal);
        assert_eq!(samples[0], Some([255, 255, 255]));
    }

    #[test]
    fn a_fully_transparent_cell_is_undrawn_even_with_a_named_background() {
        // A named background exists to soften edges, not to paint a block
        // over everything outside the picture.
        let img = image(1, 1, &[[255, 0, 0, 0]]);
        assert_eq!(
            sample_grid(img.clone(), 1, 1, ImageBackground::Rgb([10, 20, 30])),
            [None]
        );
        assert_eq!(sample_grid(img, 1, 1, ImageBackground::Terminal), [None]);
    }

    #[test]
    fn a_flat_grey_dithers_between_two_theme_colours() {
        let img = image(8, 8, &[[128, 128, 128, 255]; 64]);
        let samples = sample_grid(img, 8, 8, ImageBackground::Terminal);
        let mut budget = StyleBudget::default();
        let quantizer = Quantizer {
            palette: theme_colours(),
            full: false,
            dither: true,
            budget: &mut budget,
        };
        let colours: std::collections::HashSet<[u8; 3]> = samples
            .iter()
            .flatten()
            .enumerate()
            .map(|(i, rgb)| {
                let (x, y) = ((i % 8) as u32, (i / 8) as u32);
                rgb_of(quantizer.colour(*rgb, x, y))
            })
            .collect();
        assert!(colours.len() > 1, "a dithered flat grey must use more than one colour");

        // The same run again, byte for byte.
        let mut budget = StyleBudget::default();
        let quantizer = Quantizer {
            palette: theme_colours(),
            full: false,
            dither: true,
            budget: &mut budget,
        };
        let again: Vec<Color> = samples
            .iter()
            .flatten()
            .enumerate()
            .map(|(i, rgb)| {
                let (x, y) = ((i % 8) as u32, (i / 8) as u32);
                quantizer.colour(*rgb, x, y)
            })
            .collect();
        let first: Vec<Color> = samples
            .iter()
            .flatten()
            .enumerate()
            .map(|(i, rgb)| {
                let (x, y) = ((i % 8) as u32, (i / 8) as u32);
                theme_colours().nearest(dithered(*rgb, x, y))
            })
            .collect();
        assert_eq!(first, again);
    }

    #[test]
    fn sharpening_increases_edge_contrast() {
        // A vertical step from 80 to 180, reduced to a 16 x 2 sample grid.
        let img = RgbaImage::from_fn(16, 4, |x, _| {
            let level = if x < 8 { 80 } else { 180 };
            image::Rgba([level, level, level, 255])
        });
        let mut samples = sample(&Pixels::Rgba(img), 16, 2, 1, ImageBackground::Terminal);
        let dark_before = samples[7].expect("dark side")[0];
        let light_before = samples[8].expect("light side")[0];

        sharpen_samples(&mut samples, 16, 2);

        let dark_after = samples[7].expect("dark side")[0];
        let light_after = samples[8].expect("light side")[0];
        assert!(
            light_after - dark_after > light_before - dark_before,
            "edge contrast should rise: {dark_before}/{light_before} -> {dark_after}/{light_after}"
        );
    }

    #[test]
    fn sharpening_leaves_a_natural_size_image_alone() {
        let img = RgbaImage::from_fn(8, 8, |x, y| {
            image::Rgba([(x * 30) as u8, (y * 30) as u8, 90, 255])
        });
        let pixels = Pixels::Rgba(img);
        let mut plain = StyleBudget::default();
        let mut sharp = StyleBudget::default();
        let natural = draw(
            &pixels,
            8,
            4,
            1,
            false,
            &ImageOptions::default(),
            &mut plain,
        );
        let sharpened = draw(
            &pixels,
            8,
            4,
            1,
            false,
            &ImageOptions {
                sharpen: true,
                ..ImageOptions::default()
            },
            &mut sharp,
        );
        assert_eq!(natural, sharpened);
    }

    // ── Palette ────────────────────────────────────────────────────────────

    #[test]
    fn every_palette_colour_maps_to_itself() {
        for colour in PALETTE {
            assert_eq!(nearest_palette(rgb_of(colour)), colour);
        }
    }

    #[test]
    fn a_dark_neutral_grey_does_not_turn_colourful() {
        // The rock of a desktop wallpaper, as measured. In RGB distance the
        // palette's navy is nearer than either grey, because nothing in the
        // palette sits between black and #808080.
        for grey in [[74, 79, 85], [74, 74, 74], [60, 62, 66]] {
            let colour = nearest_palette(grey);
            let [r, g, b] = rgb_of(colour);
            assert!(r == g && g == b, "{grey:?} became {colour:?}");
        }
    }

    #[test]
    fn a_smooth_gradient_uses_no_more_colours_than_the_palette() {
        let img = RgbaImage::from_fn(64, 64, |x, y| {
            image::Rgba([(x * 4) as u8, (y * 4) as u8, ((x + y) * 2) as u8, 255])
        });
        let samples = sample_grid(img, 64, 64, ImageBackground::Terminal);
        let colours: std::collections::HashSet<[u8; 3]> = samples
            .iter()
            .flatten()
            .map(|rgb| rgb_of(theme_colours().nearest(*rgb)))
            .collect();
        assert!(colours.len() <= PALETTE.len(), "{} colours", colours.len());
    }

    #[test]
    fn an_adaptive_palette_separates_two_colours_the_cube_merges() {
        let red = [200, 30, 20];
        let blue = [20, 40, 200];
        let mut samples = vec![Some(red); 64];
        samples.extend(vec![Some(blue); 64]);

        let adaptive = ColourSet::adaptive(&samples);
        assert_eq!(adaptive.colours.len(), 2, "two distinct samples make two boxes");
        assert!(adaptive.colours.contains(&red));
        assert!(adaptive.colours.contains(&blue));

        // The cube has no entry at either point, so the distance from each
        // sample to its nearest adaptive colour is zero with the adaptive
        // palette and positive with the theme's.
        for rgb in [red, blue] {
            let index = adaptive
                .colours
                .iter()
                .position(|colour| *colour == rgb)
                .expect("the sample is a palette entry");
            assert_eq!(adaptive.nearest_index(rgb), index);
            let theme_distance =
                squared_distance(&lab(rgb), &lab(rgb_of(theme_colours().nearest(rgb))));
            assert!(theme_distance > 0.0, "{rgb:?} must not be already in the cube");
        }
    }

    #[test]
    fn an_adaptive_palette_is_the_same_on_every_run() {
        let img = RgbaImage::from_fn(40, 30, |x, y| {
            image::Rgba([(x * 6) as u8, (y * 8) as u8, ((x * y) % 256) as u8, 255])
        });
        let samples = sample_grid(img, 40, 30, ImageBackground::Terminal);
        let first = ColourSet::adaptive(&samples);
        let second = ColourSet::adaptive(&samples);
        assert_eq!(first.colours, second.colours);
    }

    #[test]
    fn the_full_palette_keeps_exact_colours_until_the_budget_runs_out() {
        let img = image(2, 1, &[[12, 34, 56, 255], [78, 90, 123, 255]]);
        let samples = sample_grid(img, 1, 1, ImageBackground::Terminal);
        let palette = ColourSet::adaptive(&samples);

        let mut budget = StyleBudget::new(1);
        let mut quantizer = Quantizer {
            palette: &palette,
            full: true,
            dither: false,
            budget: &mut budget,
        };
        assert_eq!(quantizer.colour([12, 34, 56], 0, 0), Color::Rgb(12, 34, 56));
        quantizer.note(Style::default().fg(Color::Rgb(12, 34, 56)));
        assert!(
            !quantizer.exact(),
            "one style exhausted a budget of one"
        );
        // The fallback is the adaptive palette's nearest entry, not the
        // sample itself.
        assert_eq!(
            quantizer.colour([12, 34, 56], 0, 0),
            palette.nearest([12, 34, 56])
        );
    }

    #[test]
    fn a_large_full_palette_image_stops_at_the_style_cap() {
        // A gradient wide enough that exact colours alone would run past
        // 4,096 distinct styles.
        let img = RgbaImage::from_fn(126, 200, |x, y| {
            // A deterministic pseudo-random field: far more distinct samples
            // than the cap admits.
            let n = x.wrapping_mul(2_654_435_761).wrapping_add(y * 40_503);
            image::Rgba([n as u8, (n >> 8) as u8, (n >> 16) as u8, 255])
        });
        let pixels = Pixels::Rgba(img);
        let options = ImageOptions {
            palette: ImagePalette::Full,
            ..ImageOptions::default()
        };

        let mut budget = StyleBudget::default();
        let capped = draw(&pixels, 126, 100, 1, true, &options, &mut budget);
        assert!(
            budget.len() <= MAX_IMAGE_STYLES,
            "{} styles, over the cap",
            budget.len()
        );

        // The styles emitted before the cap are the exact ones: the first
        // line is identical to an uncapped render.
        let mut unlimited = StyleBudget::new(usize::MAX);
        let exact = draw(&pixels, 126, 100, 1, true, &options, &mut unlimited);
        assert_eq!(capped[0], exact[0], "the first line must keep its exact colours");
        assert!(unlimited.len() > MAX_IMAGE_STYLES);
    }

    #[test]
    fn a_braille_full_render_of_a_photograph_is_within_the_cap() {
        // A 640 x 360 photograph-like field drawn at the page size used by
        // the reading view's widest layout.
        let img = RgbaImage::from_fn(640, 360, |x, y| {
            let noise = x.wrapping_mul(1_103_515_245).wrapping_add(y * 12_345);
            image::Rgba([
                (x / 3 + u32::from(noise as u8) / 8) as u8,
                (y / 2 + u32::from((noise >> 8) as u8) / 8) as u8,
                (((x + y) / 3 + u32::from((noise >> 16) as u8) / 8) % 256) as u8,
                255,
            ])
        });
        let mut budget = StyleBudget::default();
        let options = ImageOptions {
            palette: ImagePalette::Full,
            ..ImageOptions::default()
        };
        let lines = draw(&Pixels::Rgba(img), 126, 20, 1, true, &options, &mut budget);
        assert_eq!(lines.len(), 20);
        assert!(
            budget.len() <= MAX_IMAGE_STYLES,
            "{} styles, over the cap",
            budget.len()
        );
        // Recorded in the task list: a braille photograph at this size lands
        // well inside the bound.
        println!("braille full styles at 126x20: {}", budget.len());
    }

    // ── Encoders ───────────────────────────────────────────────────────────

    /// Run `encode` with an exact, undithered quantiser.
    fn exact_quantizer<T>(encode: impl FnOnce(&mut Quantizer) -> T) -> T {
        let palette = ColourSet::theme();
        let mut budget = StyleBudget::default();
        let mut quantizer = Quantizer {
            palette: &palette,
            full: true,
            dither: false,
            budget: &mut budget,
        };
        encode(&mut quantizer)
    }

    fn one_line(samples: &[Option<[u8; 3]>], cols: u32) -> Line {
        one_row(samples, |samples, quantizer| {
            encode_blocks(samples, cols, 1, quantizer)
        })
    }

    fn one_row(
        samples: &[Option<[u8; 3]>],
        encode: impl FnOnce(&[Option<[u8; 3]>], &mut Quantizer) -> Vec<Line>,
    ) -> Line {
        exact_quantizer(|quantizer| encode(samples, quantizer).remove(0))
    }

    #[test]
    fn both_halves_use_a_half_block_with_two_colours() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        let line = one_line(&[Some([255, 0, 0]), Some([0, 0, 255])], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn identical_halves_use_one_colour() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_line(&[Some([255, 0, 0]), Some([255, 0, 0])], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(red));
    }

    #[test]
    fn a_visible_upper_half_only_has_no_background() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_line(&[Some([255, 0, 0]), None], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn a_visible_lower_half_only_uses_the_lower_block() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_line(&[None, Some([255, 0, 0])], 1);
        assert_eq!(line.text(), "\u{2584}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn a_transparent_cell_is_a_bare_space() {
        let line = one_line(&[None, None], 1);
        assert_eq!(line.text(), " ");
        assert_eq!(line.spans[0].style, Style::default());
    }

    #[test]
    fn a_uniform_row_merges_into_one_span() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_row(&[Some([255, 0, 0]); 20], |samples, quantizer| {
            encode_blocks(samples, 10, 1, quantizer)
        });
        assert_eq!(line.spans.len(), 1);
        assert_eq!(line.text(), "\u{2580}".repeat(10));
        assert_eq!(line.spans[0].style.fg, Some(red));
    }

    #[test]
    fn a_change_of_colour_starts_a_new_span() {
        // Samples are row-major over the doubled grid: cells 0 and 1 take
        // (0, 2) and (1, 3) — so the array interleaves the two cell colours.
        let line = one_row(
            &[
                Some([255, 0, 0]),
                Some([0, 0, 255]),
                Some([255, 0, 0]),
                Some([0, 0, 255]),
            ],
            |samples, quantizer| encode_blocks(samples, 2, 1, quantizer),
        );
        assert_eq!(line.spans.len(), 2);
        assert_eq!(line.text(), "\u{2580}\u{2580}");
    }

    fn one_quad_line(samples: &[Option<[u8; 3]>], cols: u32) -> Line {
        one_row(samples, |samples, quantizer| {
            encode_quads(samples, cols, 1, quantizer)
        })
    }

    #[test]
    fn quadrants_split_a_cell_top_to_bottom() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        let line = one_quad_line(
            &[
                Some([255, 0, 0]),
                Some([255, 0, 0]),
                Some([0, 0, 255]),
                Some([0, 0, 255]),
            ],
            1,
        );
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn quadrants_split_a_cell_left_to_right() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        let line = one_quad_line(
            &[
                Some([255, 0, 0]),
                Some([0, 0, 255]),
                Some([255, 0, 0]),
                Some([0, 0, 255]),
            ],
            1,
        );
        assert_eq!(line.text(), "\u{258c}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn quadrants_split_a_cell_diagonally() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        // Upper left and lower right one colour, the other diagonal the other.
        let line = one_quad_line(
            &[
                Some([255, 0, 0]),
                Some([0, 0, 255]),
                Some([0, 0, 255]),
                Some([255, 0, 0]),
            ],
            1,
        );
        assert_eq!(line.text(), "\u{259a}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn a_uniform_quadrant_cell_is_a_full_block() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_quad_line(&[Some([255, 0, 0]); 4], 1);
        assert_eq!(line.text(), "\u{2588}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn one_visible_quadrant_uses_its_own_glyph_with_no_background() {
        let red = Color::Rgb(255, 0, 0);
        // Upper left only.
        let line = one_quad_line(&[Some([255, 0, 0]), None, None, None], 1);
        assert_eq!(line.text(), "\u{2598}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn a_partly_transparent_cell_uses_one_colour() {
        // Upper left red, lower right blue, the other two quadrants
        // transparent: no background colour may be set, or it would paint the
        // transparent quadrants.
        let line = one_quad_line(&[Some([255, 0, 0]), None, None, Some([0, 0, 255])], 1);
        assert_eq!(line.text(), "\u{259a}");
        assert_eq!(line.spans[0].style.bg, None);
        assert!(line.spans[0].style.fg.is_some());
    }

    #[test]
    fn every_quadrant_mask_has_a_glyph() {
        // A single visible quadrant for each of the four corners.
        let red = [255, 0, 0];
        let cases = [
            ([Some(red), None, None, None], '\u{2598}'), // upper left
            ([None, Some(red), None, None], '\u{259d}'), // upper right
            ([None, None, Some(red), None], '\u{2596}'), // lower left
            ([None, None, None, Some(red)], '\u{2597}'), // lower right
        ];
        for (samples, glyph) in cases {
            assert_eq!(one_quad_line(&samples, 1).text(), glyph.to_string());
        }
    }

    #[test]
    fn a_uniform_quadrant_row_merges_into_one_span() {
        let line = one_row(&[Some([255, 0, 0]); 40], |samples, quantizer| {
            encode_quads(samples, 10, 1, quantizer)
        });
        assert_eq!(line.spans.len(), 1);
        assert_eq!(line.text(), "\u{2588}".repeat(10));
    }

    // ── Braille ────────────────────────────────────────────────────────────

    /// A one-cell braille line on white paper, where the ink is the dark side.
    fn one_braille_line(samples: &[Option<[u8; 3]>]) -> Line {
        one_braille_line_on(samples, [255, 255, 255])
    }

    fn one_braille_line_on(samples: &[Option<[u8; 3]>], paper: [u8; 3]) -> Line {
        one_row(samples, |samples, quantizer| {
            encode_braille(samples, 1, 1, paper, quantizer)
        })
    }

    #[test]
    fn the_braille_bit_mapping_is_standard() {
        // Only the upper-left sub-cell is dark: dot 1, which is U+2801.
        let mut samples = [Some([255, 255, 255]); 8];
        samples[0] = Some([0, 0, 0]);
        assert_eq!(one_braille_line(&samples).text(), "\u{2801}");

        // Every dot lit is U+28FF.
        let full = one_braille_line(&[Some([0, 0, 0]); 8]);
        assert_eq!(full.text(), "\u{28ff}");
        assert_eq!(full.spans[0].style.fg, Some(Color::Rgb(0, 0, 0)));
    }

    #[test]
    fn a_uniform_dark_braille_cell_is_solid_ink() {
        let line = one_braille_line(&[Some([10, 20, 30]); 8]);
        assert_eq!(line.text(), "\u{28ff}");
        assert_eq!(line.spans[0].style.fg, Some(Color::Rgb(10, 20, 30)));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn a_uniform_light_braille_cell_is_blank() {
        let line = one_braille_line(&[Some([250, 250, 250]); 8]);
        assert_eq!(line.text(), "\u{2800}");
        assert_eq!(line.spans[0].style, Style::default());
    }

    #[test]
    fn a_dark_paper_lights_the_bright_side() {
        // The same light cell on a dark page is ink, in the light colour.
        let line = one_braille_line_on(&[Some([250, 250, 250]); 8], [30, 30, 46]);
        assert_eq!(line.text(), "\u{28ff}");
        assert_eq!(line.spans[0].style.fg, Some(Color::Rgb(250, 250, 250)));
    }

    #[test]
    fn a_white_screenshot_on_a_dark_page_inks_the_page_and_leaves_text_as_gaps() {
        // A white page has to be the ink on a dark terminal, or a screenshot
        // of a document renders as nothing but its own shadows. The dark
        // sub-cell is the gap: every dot but the first is lit.
        let mut samples = [Some([255, 255, 255]); 8];
        samples[0] = Some([0, 0, 0]);
        let line = one_braille_line_on(&samples, [30, 30, 46]);
        assert_eq!(line.text(), "\u{28fe}");
        assert_eq!(line.spans[0].style.fg, Some(Color::Rgb(255, 255, 255)));
    }

    #[test]
    fn tone_follows_distance_from_the_paper() {
        // One bit per dot can only carry tone as density: a mid grey cell on
        // a dark page must light some dots and not others, not all or none.
        let palette = ColourSet::theme();
        let mut budget = StyleBudget::default();
        let mut quantizer = Quantizer {
            palette: &palette,
            full: true,
            dither: true,
            budget: &mut budget,
        };
        let samples = [Some([128, 128, 128]); 8];
        let line = encode_braille(&samples, 1, 1, [0, 0, 0], &mut quantizer).remove(0);
        let lit = line
            .text()
            .chars()
            .next()
            .and_then(|glyph| u32::from(glyph).checked_sub(0x2800))
            .map_or(0, |bits| bits.count_ones());
        assert!(
            (2..=6).contains(&lit),
            "expected a partial cell at mid grey, got {lit} lit dots"
        );
    }

    #[test]
    fn a_vertical_edge_lights_one_column() {
        // Left column dark, right column light: dots 1, 2, 3 and 7.
        let samples: [Option<[u8; 3]>; 8] = std::array::from_fn(|index| {
            if index % 2 == 0 {
                Some([0, 0, 0])
            } else {
                Some([255, 255, 255])
            }
        });
        let line = one_braille_line(&samples);
        assert_eq!(line.text(), "\u{2847}");
        assert_eq!(line.spans[0].style.fg, Some(Color::Rgb(0, 0, 0)));
    }

    #[test]
    fn a_transparent_braille_cell_is_blank() {
        let line = one_braille_line(&[None; 8]);
        assert_eq!(line.text(), "\u{2800}");
        assert_eq!(line.spans[0].style, Style::default());
    }

    #[test]
    fn a_transparent_braille_sub_cell_is_never_lit() {
        // The upper-left is transparent, every other sub-cell is dark. Dot 1
        // must stay off, and the remaining seven dots must be on.
        let mut samples = [Some([0, 0, 0]); 8];
        samples[0] = None;
        let line = one_braille_line(&samples);
        assert_eq!(line.text(), "\u{28fe}");
    }

    // ── ASCII ──────────────────────────────────────────────────────────────

    #[test]
    fn ascii_art_is_ascii_only() {
        let samples = [
            Some([255, 0, 0]),
            Some([0, 0, 0]),
            Some([255, 255, 255]),
            None,
        ];
        let line = one_row(&samples, |samples, quantizer| {
            encode_ascii(samples, 2, 1, quantizer)
        });
        assert!(line.text().is_ascii(), "{:?}", line.text());
    }

    #[test]
    fn the_ascii_ramp_runs_from_dark_to_light() {
        let dark = exact_quantizer(|quantizer| {
            ascii_cell(Some([0, 0, 0]), Some([0, 0, 0]), quantizer, 0, 0).0
        });
        let light = exact_quantizer(|quantizer| {
            ascii_cell(Some([255, 255, 255]), Some([255, 255, 255]), quantizer, 0, 0).0
        });
        assert_eq!(dark, ASCII_RAMP[0]);
        assert_eq!(light, ASCII_RAMP[ASCII_RAMP.len() - 1]);
    }

    #[test]
    fn a_transparent_ascii_image_is_only_spaces() {
        let line = one_row(&[None, None, None, None], |samples, quantizer| {
            encode_ascii(samples, 2, 1, quantizer)
        });
        assert_eq!(line.text(), "  ");
        assert_eq!(line.spans[0].style, Style::default());
    }

    // ── The whole pipeline ─────────────────────────────────────────────────

    /// Options for one encoding, with today's conservative palette defaults.
    fn options(encoding: ImageEncoding) -> ImageOptions<'static> {
        ImageOptions {
            encoding,
            ..ImageOptions::default()
        }
    }

    #[test]
    fn a_fixture_renders_cells_from_its_pixels() {
        let path = fixture("image_cells.png");
        let mut budget = StyleBudget::default();
        let lines = artwork(
            path.to_str().unwrap(),
            Bounds { width: 80, height: None },
            &options(ImageEncoding::Blocks),
            &mut budget,
        )
        .expect("the fixture renders");

        // 4x2 pixels: one cell row of four cells.
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text(), "\u{2580}\u{2580}\u{2580} ");
    }

    #[test]
    fn the_page_height_bounds_the_artwork() {
        let path = fixture("image_sample.png");
        let mut budget = StyleBudget::default();
        let lines = artwork(
            path.to_str().unwrap(),
            Bounds { width: 80, height: Some(3) },
            &options(ImageEncoding::Blocks),
            &mut budget,
        )
        .expect("the fixture renders");
        assert_eq!(lines.len(), 3);
        assert!(lines.iter().all(|line| line.width() <= 80));
    }

    #[test]
    fn repeated_rendering_is_identical() {
        let path = fixture("image_sample.png");
        let bounds = Bounds { width: 40, height: Some(10) };
        let mut budget = StyleBudget::default();
        let first = artwork(
            path.to_str().unwrap(),
            bounds,
            &options(ImageEncoding::Blocks),
            &mut budget,
        );
        let mut budget = StyleBudget::default();
        let second = artwork(
            path.to_str().unwrap(),
            bounds,
            &options(ImageEncoding::Blocks),
            &mut budget,
        );
        assert_eq!(first, second);
    }

    #[test]
    fn the_default_encoding_is_braille() {
        assert_eq!(ImageEncoding::default(), ImageEncoding::Braille);
    }

    #[test]
    fn an_unqualified_render_emits_only_braille() {
        let path = fixture("image_sample.png");
        let mut budget = StyleBudget::default();
        let lines = artwork(
            path.to_str().unwrap(),
            Bounds { width: 40, height: None },
            &ImageOptions::default(),
            &mut budget,
        )
        .expect("the fixture renders");
        for line in &lines {
            for ch in line.text().chars() {
                assert!(
                    ('\u{2800}'..='\u{28ff}').contains(&ch),
                    "{ch:?} is outside the braille range"
                );
            }
        }
    }

    fn falls_back(dest: &str, base: Option<&Path>, budget: &mut StyleBudget) -> bool {
        let options = ImageOptions {
            base,
            ..options(ImageEncoding::Blocks)
        };
        artwork(dest, Bounds { width: 80, height: None }, &options, budget).is_none()
    }

    #[test]
    fn an_unsupported_or_missing_reference_falls_back() {
        let mut budget = StyleBudget::default();
        assert!(falls_back("image_missing.png", Some(&fixture("")), &mut budget));
        assert!(falls_back("https://example.com/a.png", None, &mut budget));
        assert!(falls_back("image_corrupt.png", Some(&fixture("")), &mut budget));
    }

    #[test]
    fn turning_images_off_produces_no_artwork() {
        let path = fixture("image_cells.png");
        let mut budget = StyleBudget::default();
        assert!(
            artwork(
                path.to_str().unwrap(),
                Bounds { width: 80, height: None },
                &options(ImageEncoding::Off),
                &mut budget,
            )
            .is_none()
        );
    }

    // ── Animation ──────────────────────────────────────────────────────────

    /// Animated artwork for a fixture, at the natural size the fixture affords.
    fn animated(name: &str) -> Artwork {
        let path = fixture(name);
        let mut budget = StyleBudget::default();
        let options = ImageOptions {
            animation: true,
            ..options(ImageEncoding::Blocks)
        };
        animated_artwork(
            path.to_str().unwrap(),
            Bounds { width: 80, height: None },
            &options,
            &mut budget,
        )
        .unwrap_or_else(|| panic!("{name} should render"))
    }

    #[test]
    fn an_animated_gif_yields_every_frame_with_its_delay() {
        let art = animated("image_animation.gif");

        // All three frames, including the first: frame 0's delay is what tells
        // a player how long to hold the static artwork before moving on.
        assert_eq!(art.frames.len(), 3);
        let delays: Vec<u32> = art.frames.iter().map(|f| f.delay_ms).collect();
        assert_eq!(delays, [40, 80, 120]);

        // The first frame is the static artwork, not merely equal to it in
        // principle: the plugin swaps frames in place, so frame 0 must be
        // exactly what the still render shows.
        assert_eq!(art.frames[0].lines, art.lines);
        // The fixture's frames are solid red, green and blue, so the encoded
        // lines must differ — three identical frames would make the delays
        // above prove nothing.
        assert_ne!(art.frames[0].lines, art.frames[1].lines);
        assert_ne!(art.frames[1].lines, art.frames[2].lines);
    }

    #[test]
    fn an_animated_webp_yields_every_frame_with_its_delay() {
        let art = animated("image_animation.webp");
        assert_eq!(art.frames.len(), 3);
        let delays: Vec<u32> = art.frames.iter().map(|f| f.delay_ms).collect();
        assert_eq!(delays, [40, 80, 120]);
        assert_eq!(art.frames[0].lines, art.lines);
    }

    #[test]
    fn still_images_carry_no_frames() {
        for name in ["image_sample.png", "image_sample.webp", "image_sample.gif"] {
            let art = animated(name);
            assert!(
                art.frames.is_empty(),
                "{name} is a still image and must not be treated as animated"
            );
            assert!(
                !art.animation_limited,
                "{name} is still, not an animation over the caps"
            );
            assert!(!art.lines.is_empty(), "{name} must still render");
        }
    }

    #[test]
    fn the_caps_admit_their_exact_bounds_and_refuse_one_past() {
        assert!(animation_within_bounds(MAX_DECODED_FRAMES, 1));
        assert!(!animation_within_bounds(MAX_DECODED_FRAMES + 1, 1));

        // The carried-frame budget is not a hard bound: more frames are
        // sampled down, not refused.
        assert!(animation_within_bounds(MAX_ANIMATION_FRAMES, 1));
        assert!(animation_within_bounds(MAX_ANIMATION_FRAMES + 1, 1));

        // 16 MP per frame: eight frames sit exactly on the 128 MP bound, a
        // ninth crosses it. The per-frame cap allows the single frame
        // (`MAX_PIXELS` is 16 MP), so only the cumulative bound can refuse the
        // ninth.
        assert!(animation_within_bounds(8, 8 * MAX_PIXELS));
        assert!(!animation_within_bounds(9, 9 * MAX_PIXELS));
        assert!(animation_within_bounds(2, MAX_ANIMATION_PIXELS));
        assert!(!animation_within_bounds(2, MAX_ANIMATION_PIXELS + 1));
    }

    #[test]
    fn halving_keeps_the_first_frame_and_every_other_one() {
        let frames = |delays: &[u32]| {
            delays
                .iter()
                .map(|&delay_ms| AnimationFrame {
                    delay_ms,
                    lines: Vec::new(),
                })
                .collect::<Vec<_>>()
        };

        let kept = halve_kept(frames(&[1, 2, 3, 4, 5, 6, 7]));
        let delays: Vec<u32> = kept.iter().map(|frame| frame.delay_ms).collect();
        // The odd positions are dropped; each survivor carries the delay of the
        // frame after it, and the last survivor carries the trailing one.
        assert_eq!(delays, vec![3, 7, 11, 7]);
        assert_eq!(
            delays.iter().sum::<u32>(),
            1 + 2 + 3 + 4 + 5 + 6 + 7,
            "halving preserves the loop's total duration"
        );
        assert_eq!(
            halve_kept(frames(&[1, 2, 3, 4, 5, 6, 7])),
            kept,
            "the same frames halve the same way on every run"
        );
    }

    #[test]
    fn a_257_frame_animation_is_sampled_instead_of_refused() {
        let art = animated("image_257.gif");
        assert!(
            !art.frames.is_empty(),
            "257 frames is over the budget, so the animation is sampled, not refused"
        );
        assert!(
            art.frames.len() <= MAX_ANIMATION_FRAMES,
            "a sampled animation still fits the carried-frame budget"
        );
        assert_eq!(
            art.frames[0].lines, art.lines,
            "the subset is anchored at the first frame"
        );
        assert!(
            !art.animation_limited,
            "a sampled animation animates, so it is not a refusal"
        );
    }

    #[test]
    fn a_256_frame_animation_still_animates() {
        // The bound is inclusive: a document may carry exactly the cap.
        let art = animated("image_256.gif");
        assert_eq!(art.frames.len(), MAX_ANIMATION_FRAMES);
        assert_eq!(art.frames[0].lines, art.lines);
    }

    #[test]
    fn a_513_frame_animation_keeps_its_recorded_duration() {
        let art = animated("image_513.gif");
        assert!(
            art.frames.len() <= MAX_ANIMATION_FRAMES,
            "the carried frames fit the budget"
        );
        assert!(art.frames.len() > 1, "a sampled animation still moves");
        assert_eq!(
            art.frames[0].lines, art.lines,
            "the subset is anchored at the first frame"
        );
        let total: u64 = art.frames.iter().map(|frame| u64::from(frame.delay_ms)).sum();
        assert_eq!(
            total, 20_470,
            "the delays of the dropped frames are folded into the kept ones"
        );
        assert!(!art.animation_limited);
        assert_eq!(
            art.frames,
            animated("image_513.gif").frames,
            "the subset is the same on every run"
        );
    }

    #[test]
    fn a_4097_frame_animation_is_refused() {
        let art = animated("image_4097.gif");
        assert!(
            art.frames.is_empty(),
            "4,097 frames is past the decoded-frame ceiling"
        );
        assert!(
            art.animation_limited,
            "the plugin needs to know the animation was refused, not absent"
        );
        assert!(!art.lines.is_empty(), "the fallback still draws the image");
    }

    #[test]
    fn the_collector_enforces_the_limits_it_is_given() {
        let path = fixture("image_animation.gif");
        // The fixture is 4x2, sampled at width 80 to one cell row of four
        // cells; three frames therefore cost 24 decoded pixels in total.
        let collect = |max_decoded_frames, max_pixels: u64, max_kept| {
            let mut budget = StyleBudget::default();
            collect_animation(
                &path,
                4,
                1,
                1,
                false,
                &options(ImageEncoding::Blocks),
                4,
                2,
                max_decoded_frames,
                max_pixels,
                max_kept,
                &mut budget,
            )
        };

        assert!(matches!(
            collect(3, 24, MAX_ANIMATION_FRAMES),
            Collected::Frames(ref frames) if frames.len() == 3
        ));
        assert!(
            matches!(collect(2, u64::MAX, MAX_ANIMATION_FRAMES), Collected::TooLarge),
            "one frame past the decoded-frame ceiling"
        );
        assert!(
            matches!(collect(3, 23, MAX_ANIMATION_FRAMES), Collected::TooLarge),
            "one pixel past the area cap"
        );
        assert!(matches!(
            collect(3, u64::MAX, MAX_ANIMATION_FRAMES),
            Collected::Frames(ref frames) if frames.len() == 3
        ));

        // The carried-frame budget samples rather than refuses: a budget of
        // two carries the first frame plus the one it is folded into.
        assert!(matches!(
            collect(3, u64::MAX, 2),
            Collected::Frames(ref frames)
                if frames.len() == 2 && frames[0].delay_ms == 40 + 80
        ));
    }
}
