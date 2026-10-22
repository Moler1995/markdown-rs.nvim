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

/// The most frames an animated image may contribute.
///
/// A frame costs a decode and a set of lines on the wire, and a resize
/// re-renders the document, so an image with thousands of frames is not
/// something a reading view can honour. Past this bound the image renders as
/// its first frame with no animation data at all (see [`MAX_ANIMATION_PIXELS`]).
pub const MAX_ANIMATION_FRAMES: usize = 256;

/// The most decoded pixels an animation may cost, cumulatively.
///
/// [`MAX_PIXELS`] bounds one frame; a hundred 16-megapixel frames would still
/// be a hundred decodes. The frames are sampled and turned into lines as they
/// arrive, so peak memory stays at one frame — this bound is about decode CPU
/// and the size of the render request, not memory.
///
/// 64 megapixels covers a common 640 × 360 GIF of 189 frames (43.5 MP) with
/// room to spare, while still refusing the animations whose first step would
/// take seconds. It is twice the original 32 MP because that bound rejected a
/// real-world GIF that was otherwise ordinary.
pub const MAX_ANIMATION_PIXELS: u64 = 64_000_000;

/// Alpha below this is treated as transparent.
///
/// A terminal's background is not known here, so semi-transparent pixels have
/// to be decided rather than blended: at or above the threshold the pixel is
/// ink, below it the cell shows what is behind.
const ALPHA_THRESHOLD: u8 = 128;

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
    /// Half blocks: upper and lower halves, one colour each.
    #[default]
    Blocks,
    /// Quadrants: four sub-cells in two colours, twice the horizontal detail.
    Quads,
    /// ASCII glyphs from the luminance ramp, one colour per cell.
    Ascii,
    /// No artwork; the reference reads as its alt text.
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
}

/// One decoded frame of an animated image, drawn at the document's width.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnimationFrame {
    /// How long the frame is shown, in milliseconds, as the file records it.
    pub delay_ms: u32,
    /// The frame's display lines, in the same cell grid as the first frame.
    pub lines: Vec<Line>,
}

/// An image drawn for animation: the first frame, plus every frame when the
/// image animates within the caps.
///
/// `frames` is empty for a still image, a reference that does not resolve, and
/// an animation that exceeds [`MAX_ANIMATION_FRAMES`] or
/// [`MAX_ANIMATION_PIXELS`]. In every one of those cases `lines` is the same
/// artwork an ordinary render produces, so the static view is unchanged.
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
    encoding: ImageEncoding,
    base: Option<&Path>,
) -> Option<Vec<Line>> {
    if encoding == ImageEncoding::Off {
        return None;
    }
    let path = resolve(dest, base)?;
    let image = load(&path)?;
    let (cols, rows) = cell_grid(image.width(), image.height(), bounds)?;
    Some(draw(&image, cols, rows, encoding))
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
    encoding: ImageEncoding,
    base: Option<&Path>,
) -> Option<Artwork> {
    if encoding == ImageEncoding::Off {
        return None;
    }
    let path = resolve(dest, base)?;
    let image = load(&path)?;
    let (cols, rows) = cell_grid(image.width(), image.height(), bounds)?;
    let lines = draw(&image, cols, rows, encoding);
    let collected = collect_animation(
        &path,
        cols,
        rows,
        encoding,
        image.width(),
        image.height(),
        MAX_ANIMATION_FRAMES,
        MAX_ANIMATION_PIXELS,
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

/// Sample `image` onto the cell grid and encode it.
fn draw(image: &Pixels, cols: u32, rows: u32, encoding: ImageEncoding) -> Vec<Line> {
    // Quadrants sample two sub-cells across, so they ask the box filter for
    // twice the grid width. The rows are the same for every encoding.
    let grid_cols = match encoding {
        ImageEncoding::Quads => cols * 2,
        _ => cols,
    };
    let samples = sample(image, grid_cols, rows);

    match encoding {
        ImageEncoding::Blocks => encode_blocks(&samples, cols, rows),
        ImageEncoding::Quads => encode_quads(&samples, cols, rows),
        ImageEncoding::Ascii => encode_ascii(&samples, cols, rows),
        // The caller refuses `Off` before reaching here; kept so the match is
        // total.
        ImageEncoding::Off => Vec::new(),
    }
}

/// True when an animation of `frame_count` frames that decodes `pixels` pixels
/// in total is within the animation caps.
///
/// Both bounds are inclusive: an image of exactly [`MAX_ANIMATION_FRAMES`] or
/// exactly [`MAX_ANIMATION_PIXELS`] still animates.
#[must_use]
pub fn animation_within_bounds(frame_count: usize, pixels: u64) -> bool {
    within_bounds(frame_count, pixels, MAX_ANIMATION_FRAMES, MAX_ANIMATION_PIXELS)
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
    /// The animation exists but is past `max_frames` or `max_pixels`.
    TooLarge,
    /// Every frame, in file order.
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
fn collect_animation(
    path: &Path,
    cols: u32,
    rows: u32,
    encoding: ImageEncoding,
    width: u32,
    height: u32,
    max_frames: usize,
    max_pixels: u64,
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

    let mut out = Vec::new();
    let mut pixels = 0u64;
    for frame in frames {
        let Ok(frame) = frame else {
            return Collected::Still;
        };
        let count = out.len() + 1;
        let Some(total) = pixels.checked_add(frame_pixels) else {
            return Collected::TooLarge;
        };
        pixels = total;
        if !within_bounds(count, pixels, max_frames, max_pixels) {
            return Collected::TooLarge;
        }
        let delay_ms = delay_ms(frame.delay());
        let image = Pixels::new(DynamicImage::ImageRgba8(frame.into_buffer()));
        out.push(AnimationFrame {
            delay_ms,
            lines: draw(&image, cols, rows, encoding),
        });
    }
    Collected::Frames(out)
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
/// tall. Both bounds apply together and the image is never enlarged: a 16-pixel
/// icon stays 16 columns wide on an 80-column page. `None` means no room for a
/// single cell.
fn cell_grid(src_w: u32, src_h: u32, bounds: Bounds) -> Option<(u32, u32)> {
    if src_w == 0 || src_h == 0 || bounds.width == 0 {
        return None;
    }

    let natural_cols = f64::from(src_w);
    let natural_rows = f64::from(src_h.div_ceil(2));
    let width = f64::from(bounds.width);

    let mut scale = 1.0_f64.min(width / natural_cols);
    if let Some(height) = bounds.height {
        if height == 0 {
            return None;
        }
        scale = scale.min(f64::from(height) / natural_rows);
    }

    let cols = (natural_cols * scale)
        .round()
        .clamp(1.0, width) as u32;
    let mut rows = (natural_rows * scale).round().max(1.0) as u32;
    if let Some(height) = bounds.height {
        rows = rows.clamp(1, u32::from(height));
    }
    Some((cols, rows))
}

/// Average `image` down to a `cols` × `2·rows` grid of palette colours, or
/// `None` for a cell region with no opaque pixels.
///
/// Each output sample covers an integer band of the source. The bands are
/// monotone and together cover every source pixel once, so the pass is linear
/// in the source and needs no floating-point edge weights.
fn sample(image: &Pixels, cols: u32, rows: u32) -> Vec<Option<Color>> {
    match image {
        Pixels::Rgb(image) => {
            sample_channels::<3>(image.as_raw(), image.width(), image.height(), cols, rows)
        }
        Pixels::Rgba(image) => {
            sample_channels::<4>(image.as_raw(), image.width(), image.height(), cols, rows)
        }
    }
}

/// [`sample`] over a flat buffer of `N`-byte pixels (3 = RGB, 4 = RGBA).
///
/// The channel count is a const generic so the alpha test disappears from the
/// RGB instantiation instead of branching twelve million times.
fn sample_channels<const N: usize>(
    buffer: &[u8],
    src_w: u32,
    src_h: u32,
    cols: u32,
    rows: u32,
) -> Vec<Option<Color>> {
    let grid_rows = rows * 2;
    let stride = src_w as usize * N;
    let mut out = Vec::with_capacity((cols * grid_rows) as usize);

    for y in 0..grid_rows {
        let (y0, y1) = band(src_h, grid_rows, y);
        for x in 0..cols {
            let (x0, x1) = band(src_w, cols, x);
            out.push(average_region::<N>(buffer, stride, x0, x1, y0, y1).map(nearest_palette));
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

/// The mean colour of the opaque pixels in a rectangle, if there are any.
///
/// The rectangle is walked over row slices of the raw buffer rather than
/// through `get_pixel`, whose per-pixel bounds check cost about 20 ms on a
/// twelve-megapixel image.
fn average_region<const N: usize>(
    buffer: &[u8],
    stride: usize,
    x0: u32,
    x1: u32,
    y0: u32,
    y1: u32,
) -> Option<[u8; 3]> {
    let mut sums = [0u64; 3];
    let mut count = 0u64;

    for y in y0..y1 {
        let start = y as usize * stride;
        let row = &buffer[start..start + stride];
        for x in x0..x1 {
            let i = x as usize * N;
            if N == 4 && row[i + 3] < ALPHA_THRESHOLD {
                continue;
            }
            sums[0] += u64::from(row[i]);
            sums[1] += u64::from(row[i + 1]);
            sums[2] += u64::from(row[i + 2]);
            count += 1;
        }
    }

    if count == 0 {
        return None;
    }
    Some([
        u8::try_from(sums[0] / count).unwrap_or(0),
        u8::try_from(sums[1] / count).unwrap_or(0),
        u8::try_from(sums[2] / count).unwrap_or(0),
    ])
}

/// The palette colour closest to `rgb`, measured in CIELAB.
///
/// Distance is taken in CIELAB rather than in RGB because RGB distance is
/// channel-wise, and channel-wise distance cannot tell a neutral colour from a
/// saturated one that happens to sit at the same point per channel. Measured
/// on a desktop screenshot, plain RGB sent the dark grey rock of a wallpaper to
/// navy: at (74, 79, 85) the rock's blue channel is nearer 128 than 0, so
/// `#000080` beat both `#000000` and `#808080`. The palette has no mid-dark
/// grey to fall back on, so several hundred cells speckled blue. CIELAB
/// compares lightness and hue separately and sends the same grey to `#808080`.
fn nearest_palette(rgb: [u8; 3]) -> Color {
    PALETTE[nearest_palette_index(rgb)]
}

/// The index in [`PALETTE`] of the colour closest to `rgb`, measured in CIELAB.
///
/// [`quad_cell`] works with indices rather than colours because it scores
/// fourteen candidate colours per cell, and the palette's CIELAB coordinates
/// are already computed: returning the index keeps the Lab conversion to the
/// one target colour instead of converting every candidate back.
fn nearest_palette_index(rgb: [u8; 3]) -> usize {
    let target = lab(rgb);
    let mut best = 0;
    let mut best_distance = f32::MAX;

    for (index, entry) in palette_lab().iter().enumerate() {
        let distance = squared_distance(&target, entry);
        if distance < best_distance {
            best_distance = distance;
            best = index;
        }
    }

    best
}

/// Squared distance between two CIELAB colours.
fn squared_distance(a: &[f32; 3], b: &[f32; 3]) -> f32 {
    (0..3).map(|i| (a[i] - b[i]).powi(2)).sum()
}

/// The palette's CIELAB coordinates, computed once for the life of the process.
fn palette_lab() -> &'static [[f32; 3]; PALETTE.len()] {
    static LAB: OnceLock<[[f32; 3]; PALETTE.len()]> = OnceLock::new();
    LAB.get_or_init(|| PALETTE.map(|colour| lab(rgb_of(colour))))
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
fn ascii_cell(upper: Option<Color>, lower: Option<Color>) -> (char, Style) {
    let colour = match (upper, lower) {
        (None, None) => return (' ', Style::default()),
        (Some(only), None) | (None, Some(only)) => only,
        (Some(a), Some(b)) => {
            let [ar, ag, ab] = rgb_of(a);
            let [br, bg, bb] = rgb_of(b);
            let mean = [
                u8::try_from((u16::from(ar) + u16::from(br)) / 2).unwrap_or(0),
                u8::try_from((u16::from(ag) + u16::from(bg)) / 2).unwrap_or(0),
                u8::try_from((u16::from(ab) + u16::from(bb)) / 2).unwrap_or(0),
            ];
            nearest_palette(mean)
        }
    };

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
fn encode_blocks(samples: &[Option<Color>], cols: u32, rows: u32) -> Vec<Line> {
    let mut lines = Vec::with_capacity(rows as usize);

    for row in 0..rows {
        let mut line = Line::new();
        for col in 0..cols {
            let upper = samples[(row * 2 * cols + col) as usize];
            let lower = samples[((row * 2 + 1) * cols + col) as usize];
            let (glyph, style) = half_block(upper, lower);
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
fn encode_quads(samples: &[Option<Color>], cols: u32, rows: u32) -> Vec<Line> {
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
            let (glyph, style) = quad_cell(quadrants);
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
fn quad_cell(quadrants: [Option<Color>; 4]) -> (char, Style) {
    let mut mask = 0u8;
    let mut present = [Color::Rgb(0, 0, 0); 4];
    let mut count = 0;

    for (i, quadrant) in quadrants.iter().enumerate() {
        if let Some(colour) = *quadrant {
            mask |= 1u8 << i;
            present[count] = colour;
            count += 1;
        }
    }

    if count == 0 {
        return (' ', Style::default());
    }
    if count < 4 {
        let colour = nearest_palette(mean(&present[..count]));
        return (QUADRANTS[usize::from(mask)], Style::default().fg(colour));
    }

    let labs = present.map(|colour| lab(rgb_of(colour)));
    let palette = palette_lab();
    let mut best = (f32::MAX, 0u8, 0usize, 0usize);

    for &partition in &PARTITIONS {
        let mut sums = [[0u32; 3]; 2];
        let mut counts = [0u32; 2];
        for (i, colour) in present.iter().enumerate() {
            let side = usize::from(partition >> i & 1 == 0);
            let [r, g, b] = rgb_of(*colour);
            sums[side][0] += u32::from(r);
            sums[side][1] += u32::from(g);
            sums[side][2] += u32::from(b);
            counts[side] += 1;
        }

        let fg = nearest_palette_index(average(sums[0], counts[0]));
        let bg = nearest_palette_index(average(sums[1], counts[1]));
        let (fg_lab, bg_lab) = (&palette[fg], &palette[bg]);

        let cost: f32 = (0..4)
            .map(|i| {
                let target = if partition >> i & 1 == 1 { fg_lab } else { bg_lab };
                squared_distance(&labs[i], target)
            })
            .sum();
        if cost < best.0 {
            best = (cost, partition, fg, bg);
        }
    }

    let (_, partition, fg, bg) = best;
    let (fg, bg) = (PALETTE[fg], PALETTE[bg]);
    if fg == bg {
        return ('\u{2588}', Style::default().fg(fg));
    }
    (
        QUADRANTS[usize::from(partition)],
        Style::default().fg(fg).bg(bg),
    )
}

/// The mean of a non-empty slice of colours.
fn mean(colours: &[Color]) -> [u8; 3] {
    let mut sums = [0u32; 3];
    for colour in colours {
        let [r, g, b] = rgb_of(*colour);
        sums[0] += u32::from(r);
        sums[1] += u32::from(g);
        sums[2] += u32::from(b);
    }
    average(sums, u32::try_from(colours.len()).unwrap_or(1))
}

/// `sum / count` per channel, as a colour. `count` is never zero.
fn average(sums: [u32; 3], count: u32) -> [u8; 3] {
    [
        u8::try_from(sums[0] / count).unwrap_or(0),
        u8::try_from(sums[1] / count).unwrap_or(0),
        u8::try_from(sums[2] / count).unwrap_or(0),
    ]
}

/// Draw the sampled grid with the ASCII ramp.
fn encode_ascii(samples: &[Option<Color>], cols: u32, rows: u32) -> Vec<Line> {
    let mut lines = Vec::with_capacity(rows as usize);

    for row in 0..rows {
        let mut line = Line::new();
        for col in 0..cols {
            let upper = samples[(row * 2 * cols + col) as usize];
            let lower = samples[((row * 2 + 1) * cols + col) as usize];
            let (glyph, style) = ascii_cell(upper, lower);
            push_cell(&mut line, glyph, style);
        }
        lines.push(line);
    }

    lines
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
            cell_grid(1200, 600, Bounds { width: 80, height: None }),
            Some((80, 20))
        );
    }

    #[test]
    fn a_narrow_image_is_not_enlarged() {
        assert_eq!(
            cell_grid(16, 8, Bounds { width: 80, height: None }),
            Some((16, 4))
        );
    }

    #[test]
    fn the_height_bound_binds_first() {
        // 400x2000 at width 80 would be 100 rows; the page has 40.
        let (cols, rows) = cell_grid(400, 2000, Bounds { width: 80, height: Some(40) }).unwrap();
        assert_eq!(rows, 40);
        assert!(cols <= 80);
        // The aspect ratio survives: cols/rows ≈ 2 * 400/2000.
        assert!((f64::from(cols) / f64::from(rows) - 0.4).abs() < 0.1);
    }

    #[test]
    fn a_short_image_keeps_its_natural_height_on_a_tall_page() {
        assert_eq!(
            cell_grid(20, 10, Bounds { width: 80, height: Some(40) }),
            Some((20, 5))
        );
    }

    #[test]
    fn no_room_for_a_cell_is_a_fallback() {
        assert_eq!(cell_grid(10, 10, Bounds { width: 0, height: None }), None);
        assert_eq!(cell_grid(10, 10, Bounds { width: 80, height: Some(0) }), None);
        assert_eq!(cell_grid(0, 10, Bounds { width: 80, height: None }), None);
        assert_eq!(cell_grid(10, 0, Bounds { width: 80, height: None }), None);
    }

    // ── Sampling ───────────────────────────────────────────────────────────

    #[test]
    fn a_flat_region_averages_to_its_own_colour() {
        let img = image(2, 2, &[[255, 0, 0, 255]; 4]);
        let samples = sample(&Pixels::Rgba(img), 1, 1);
        assert_eq!(samples, [Some(Color::Rgb(255, 0, 0)), Some(Color::Rgb(255, 0, 0))]);
    }

    #[test]
    fn a_transparent_region_samples_as_none() {
        let img = image(2, 2, &[[255, 0, 0, 0]; 4]);
        let samples = sample(&Pixels::Rgba(img), 1, 1);
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
        let samples = sample(&Pixels::Rgba(img), 1, 1);
        assert_eq!(samples, [Some(Color::Rgb(255, 0, 0)), Some(Color::Rgb(255, 0, 0))]);
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
        let samples = sample(&Pixels::Rgba(img), 64, 32);
        let colours: std::collections::HashSet<&Color> = samples.iter().flatten().collect();
        assert!(colours.len() <= PALETTE.len(), "{} colours", colours.len());
    }

    // ── Encoders ───────────────────────────────────────────────────────────

    fn one_line(samples: &[Option<Color>], cols: u32) -> Line {
        encode_blocks(samples, cols, 1).remove(0)
    }

    #[test]
    fn both_halves_use_a_half_block_with_two_colours() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        let line = one_line(&[Some(red), Some(blue)], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn identical_halves_use_one_colour() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_line(&[Some(red), Some(red)], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(red));
    }

    #[test]
    fn a_visible_upper_half_only_has_no_background() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_line(&[Some(red), None], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn a_visible_lower_half_only_uses_the_lower_block() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_line(&[None, Some(red)], 1);
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
        let line = encode_blocks(&[Some(red); 20], 10, 1).remove(0);
        assert_eq!(line.spans.len(), 1);
        assert_eq!(line.text(), "\u{2580}".repeat(10));
    }

    #[test]
    fn a_change_of_colour_starts_a_new_span() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        // Samples are row-major over the doubled grid: cells 0 and 1 take
        // (0, 2) and (1, 3) — so the array interleaves the two cell colours.
        let line = encode_blocks(&[Some(red), Some(blue), Some(red), Some(blue)], 2, 1).remove(0);
        assert_eq!(line.spans.len(), 2);
        assert_eq!(line.text(), "\u{2580}\u{2580}");
    }

    fn one_quad_line(samples: &[Option<Color>], cols: u32) -> Line {
        encode_quads(samples, cols, 1).remove(0)
    }

    #[test]
    fn quadrants_split_a_cell_top_to_bottom() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        let line = one_quad_line(&[Some(red), Some(red), Some(blue), Some(blue)], 1);
        assert_eq!(line.text(), "\u{2580}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn quadrants_split_a_cell_left_to_right() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        let line = one_quad_line(&[Some(red), Some(blue), Some(red), Some(blue)], 1);
        assert_eq!(line.text(), "\u{258c}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn quadrants_split_a_cell_diagonally() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        // Upper left and lower right one colour, the other diagonal the other.
        let line = one_quad_line(&[Some(red), Some(blue), Some(blue), Some(red)], 1);
        assert_eq!(line.text(), "\u{259a}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, Some(blue));
    }

    #[test]
    fn a_uniform_quadrant_cell_is_a_full_block() {
        let red = Color::Rgb(255, 0, 0);
        let line = one_quad_line(&[Some(red); 4], 1);
        assert_eq!(line.text(), "\u{2588}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn one_visible_quadrant_uses_its_own_glyph_with_no_background() {
        let red = Color::Rgb(255, 0, 0);
        // Upper left only.
        let line = one_quad_line(&[Some(red), None, None, None], 1);
        assert_eq!(line.text(), "\u{2598}");
        assert_eq!(line.spans[0].style.fg, Some(red));
        assert_eq!(line.spans[0].style.bg, None);
    }

    #[test]
    fn a_partly_transparent_cell_uses_one_colour() {
        let red = Color::Rgb(255, 0, 0);
        let blue = Color::Rgb(0, 0, 255);
        // Upper left red, lower right blue, the other two quadrants
        // transparent: no background colour may be set, or it would paint the
        // transparent quadrants.
        let line = one_quad_line(&[Some(red), None, None, Some(blue)], 1);
        assert_eq!(line.text(), "\u{259a}");
        assert_eq!(line.spans[0].style.bg, None);
        assert!(line.spans[0].style.fg.is_some());
    }

    #[test]
    fn every_quadrant_mask_has_a_glyph() {
        // A single visible quadrant for each of the four corners.
        let red = Color::Rgb(255, 0, 0);
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
        let red = Color::Rgb(255, 0, 0);
        let line = encode_quads(&[Some(red); 40], 10, 1).remove(0);
        assert_eq!(line.spans.len(), 1);
        assert_eq!(line.text(), "\u{2588}".repeat(10));
    }

    #[test]
    fn ascii_art_is_ascii_only() {
        let red = Color::Rgb(255, 0, 0);
        let white = Color::Rgb(255, 255, 255);
        let black = Color::Rgb(0, 0, 0);
        let samples = [Some(red), Some(black), Some(white), None];
        let line = encode_ascii(&samples, 2, 1).remove(0);
        assert!(line.text().is_ascii(), "{:?}", line.text());
    }

    #[test]
    fn the_ascii_ramp_runs_from_dark_to_light() {
        let black = Color::Rgb(0, 0, 0);
        let white = Color::Rgb(255, 255, 255);
        let dark = ascii_cell(Some(black), Some(black)).0;
        let light = ascii_cell(Some(white), Some(white)).0;
        assert_eq!(dark, ASCII_RAMP[0]);
        assert_eq!(light, ASCII_RAMP[ASCII_RAMP.len() - 1]);
    }

    #[test]
    fn a_transparent_ascii_image_is_only_spaces() {
        let line = encode_ascii(&[None, None, None, None], 2, 1).remove(0);
        assert_eq!(line.text(), "  ");
        assert_eq!(line.spans[0].style, Style::default());
    }

    // ── The whole pipeline ─────────────────────────────────────────────────

    #[test]
    fn a_fixture_renders_cells_from_its_pixels() {
        let path = fixture("image_cells.png");
        let lines = artwork(
            path.to_str().unwrap(),
            Bounds { width: 80, height: None },
            ImageEncoding::Blocks,
            None,
        )
        .expect("the fixture renders");

        // 4x2 pixels: one cell row of four cells.
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text(), "\u{2580}\u{2580}\u{2580} ");
    }

    #[test]
    fn the_page_height_bounds_the_artwork() {
        let path = fixture("image_sample.png");
        let lines = artwork(
            path.to_str().unwrap(),
            Bounds { width: 80, height: Some(3) },
            ImageEncoding::Blocks,
            None,
        )
        .expect("the fixture renders");
        assert_eq!(lines.len(), 3);
        assert!(lines.iter().all(|line| line.width() <= 80));
    }

    #[test]
    fn repeated_rendering_is_identical() {
        let path = fixture("image_sample.png");
        let bounds = Bounds { width: 40, height: Some(10) };
        let first = artwork(path.to_str().unwrap(), bounds, ImageEncoding::Blocks, None);
        let second = artwork(path.to_str().unwrap(), bounds, ImageEncoding::Blocks, None);
        assert_eq!(first, second);
    }

    #[test]
    fn an_unsupported_or_missing_reference_falls_back() {
        assert!(artwork("image_missing.png", Bounds { width: 80, height: None }, ImageEncoding::Blocks, Some(&fixture(""))).is_none());
        assert!(artwork("https://example.com/a.png", Bounds { width: 80, height: None }, ImageEncoding::Blocks, None).is_none());
        assert!(artwork("image_corrupt.png", Bounds { width: 80, height: None }, ImageEncoding::Blocks, Some(&fixture(""))).is_none());
    }

    #[test]
    fn turning_images_off_produces_no_artwork() {
        let path = fixture("image_cells.png");
        assert!(artwork(path.to_str().unwrap(), Bounds { width: 80, height: None }, ImageEncoding::Off, None).is_none());
    }

    // ── Animation ──────────────────────────────────────────────────────────

    /// Animated artwork for a fixture, at the natural size the fixture affords.
    fn animated(name: &str) -> Artwork {
        let path = fixture(name);
        animated_artwork(
            path.to_str().unwrap(),
            Bounds { width: 80, height: None },
            ImageEncoding::Blocks,
            None,
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
        assert!(animation_within_bounds(MAX_ANIMATION_FRAMES, 1));
        assert!(!animation_within_bounds(MAX_ANIMATION_FRAMES + 1, 1));

        // 16 MP per frame: four frames sit exactly on the 64 MP bound, a fifth
        // crosses it. The per-frame cap allows the single frame (`MAX_PIXELS`
        // is 16 MP), so only the cumulative bound can refuse the fifth.
        assert!(animation_within_bounds(4, 4 * MAX_PIXELS));
        assert!(!animation_within_bounds(5, 5 * MAX_PIXELS));
        assert!(animation_within_bounds(2, MAX_ANIMATION_PIXELS));
        assert!(!animation_within_bounds(2, MAX_ANIMATION_PIXELS + 1));
    }

    #[test]
    fn a_257_frame_animation_falls_back_to_its_first_frame() {
        let art = animated("image_257.gif");
        assert!(
            art.frames.is_empty(),
            "257 frames exceeds the cap, and the fallback is the first frame alone"
        );
        assert!(
            art.animation_limited,
            "the plugin needs to know the animation was refused, not absent"
        );
        assert!(!art.lines.is_empty(), "the fallback still draws the image");
    }

    #[test]
    fn a_256_frame_animation_still_animates() {
        // The bound is inclusive: a document may carry exactly the cap.
        let art = animated("image_256.gif");
        assert_eq!(art.frames.len(), MAX_ANIMATION_FRAMES);
        assert_eq!(art.frames[0].lines, art.lines);
    }

    #[test]
    fn the_collector_enforces_the_limits_it_is_given() {
        let path = fixture("image_animation.gif");
        // The fixture is 4x2, sampled at width 80 to one cell row of four
        // cells; three frames therefore cost 24 decoded pixels in total.
        let collect = |max_frames, max_pixels| {
            collect_animation(
                &path,
                4,
                1,
                ImageEncoding::Blocks,
                4,
                2,
                max_frames,
                max_pixels,
            )
        };

        assert!(matches!(
            collect(3, 24),
            Collected::Frames(ref frames) if frames.len() == 3
        ));
        assert!(
            matches!(collect(2, u64::MAX), Collected::TooLarge),
            "one frame past the count cap"
        );
        assert!(
            matches!(collect(3, 23), Collected::TooLarge),
            "one pixel past the area cap"
        );
        assert!(matches!(
            collect(3, u64::MAX),
            Collected::Frames(ref frames) if frames.len() == 3
        ));
    }
}
