//! `md-render` — render a markdown document to the wire format on stdout.
//!
//! ```text
//! md-render --width 120 --theme nord path/to/file.md
//! cat file.md | md-render --width 120
//! ```
//!
//! The width is required. There is no sensible default: the engine lays out
//! tables and diagrams against a column budget, and a guess would produce
//! output the caller then has to discard. Making it mandatory means a caller
//! that forgets it gets an error rather than a subtly wrong render.

use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

use md_render::document::{layout_document, source_line_count};
use md_render::image_art::{
    DitherMode, ImageBackground, ImageEncoding, ImageOptions, ImagePalette,
};
use md_render::style::Color;
use md_render::renderer::render_markdown;
use md_render::theme::{Palette, Theme};

/// Render markdown to styled display lines.
#[derive(Debug, Parser)]
#[command(name = "md-render", version, about, long_about = None)]
struct Cli {
    /// Display width in columns.
    ///
    /// Every emitted line fits within this many columns.
    ///
    /// Required for a render, but not for `--themes`, which exits before a
    /// width could mean anything.
    #[arg(long, required_unless_present = "themes")]
    width: Option<u16>,

    /// Colour theme.
    ///
    /// One of the names listed by `md-render --themes`.
    #[arg(long, default_value = "default")]
    theme: String,

    /// Directory that relative image destinations resolve against.
    ///
    /// Defaults to the working directory. Absolute destinations and URLs are
    /// unaffected; a URL is never fetched.
    #[arg(long, value_name = "DIR")]
    base: Option<PathBuf>,

    /// Maximum height an image may occupy, in display rows.
    ///
    /// Omitted, an image is bounded by the width alone. A bound of zero leaves
    /// no room for a cell, so every image falls back to its alt text.
    #[arg(long, value_name = "ROWS")]
    image_max_height: Option<u16>,

    /// How images are drawn.
    ///
    /// `braille` uses eight dots in a 2 × 4 grid and one colour per cell;
    /// `quads` uses quadrant glyphs, four sub-cells in two colours; `blocks`
    /// uses half-block glyphs and two colours per cell; `ascii` uses one
    /// characteristic glyph and one colour; and `off` renders references as
    /// their alt text.
    #[arg(long, value_enum, default_value = "braille")]
    image_encoding: ImageEncoding,

    /// Where image cell colours come from.
    ///
    /// `theme` is the fixed sixty-four-colour cube; `adaptive` cuts sixty-four
    /// colours from the image itself; `full` emits sampled colours exactly,
    /// up to the document's style bound and quantised after it.
    #[arg(long, value_enum, default_value = "theme")]
    image_palette: ImagePalette,

    /// What partly transparent image pixels are composited against.
    ///
    /// `terminal` leaves them to the terminal (the default); `theme` uses the
    /// selected theme's background; `#rrggbb` names a colour.
    #[arg(long, default_value = "terminal", value_name = "terminal|theme|#rrggbb")]
    image_background: String,

    /// The colour braille artwork is drawn on.
    ///
    /// Braille has one colour per cell and one bit per dot, so it draws a
    /// picture as ink on paper: the dots carry whichever side of a sub-cell is
    /// away from the paper. On a dark page a white screenshot becomes a field
    /// of light dots with its text left as gaps; on a light page the sketch is
    /// dark instead. Defaults to what the background resolves to, or the
    /// theme's background when transparency is left to the terminal.
    #[arg(long, value_name = "#rrggbb")]
    image_paper: Option<String>,

    /// Whether image quantisation is ordered-dithered.
    ///
    /// `auto` enables it for braille, and for ASCII with a reduced palette;
    /// `on` and `off` force it. Off by default, as before.
    #[arg(long, value_enum, default_value = "off", value_name = "auto|on|off")]
    image_dither: DitherMode,

    /// Enlarge an image to at least this many display rows.
    ///
    /// Zero (the default) never enlarges. A positive value enlarges by the
    /// smallest whole factor from 2 to 4 that reaches the count, without
    /// crossing the width or height bounds.
    #[arg(long, default_value_t = 0, value_name = "ROWS")]
    image_min_rows: u16,

    /// Sharpen an image that was reduced to fit the page.
    #[arg(long)]
    image_sharpen: bool,

    /// Also emit the frames of animated GIF and WebP images.
    ///
    /// Off by default: an image is drawn on its first frame. With this flag an
    /// animated image additionally carries its frames in the document's
    /// `animations` field, so a reader can step through or play them.
    #[arg(long)]
    image_animation: bool,

    /// Markdown file to render. Reads standard input when omitted.
    path: Option<PathBuf>,

    /// Print the available theme names and exit.
    #[arg(long)]
    themes: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    if cli.themes {
        for theme in Theme::ALL {
            println!("{}", theme_name(*theme));
        }
        return ExitCode::SUCCESS;
    }

    match run(&cli) {
        Ok(json) => match write_stdout(&json) {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => fail(&format!("could not write output: {err}")),
        },
        Err(err) => fail(&err),
    }
}

fn fail(message: &str) -> ExitCode {
    // stderr, not stdout: stdout carries the document and nothing else.
    let _ = writeln!(io::stderr(), "md-render: {message}");
    ExitCode::FAILURE
}

fn run(cli: &Cli) -> Result<String, String> {
    // clap guarantees a width here: it is required unless `--themes` is set,
    // and that path returns before reaching `run`.
    let width = cli.width.unwrap_or(0);
    if width == 0 {
        return Err("--width must be at least 1".to_string());
    }

    let theme = parse_theme(&cli.theme)?;
    let content = read_input(cli.path.as_ref())?;

    let palette = Palette::from_theme(theme);
    let background = parse_background(&cli.image_background, &palette)?;
    // Braille's page is whatever the image is composited onto, so a named
    // background doubles as the paper; `terminal` leaves both to the caller.
    let paper = match (&cli.image_paper, background) {
        (Some(hex), _) => Some(parse_hex(hex, "--image-paper")?),
        (None, ImageBackground::Rgb(rgb)) => Some(rgb),
        (None, ImageBackground::Terminal) => None,
    };
    let blocks = render_markdown(&content, &palette, theme);
    let images = ImageOptions {
        base: cli.base.as_deref(),
        max_height: cli.image_max_height,
        encoding: cli.image_encoding,
        animation: cli.image_animation,
        palette: cli.image_palette,
        background,
        dither: cli.image_dither,
        min_rows: cli.image_min_rows,
        sharpen: cli.image_sharpen,
        paper,
    };
    let doc = layout_document(
        &blocks,
        width,
        &palette,
        source_line_count(&content),
        images,
    );

    serde_json::to_string(&doc).map_err(|err| format!("could not serialise the document: {err}"))
}

/// Resolve `--image-background` against the selected theme.
fn parse_background(value: &str, palette: &Palette) -> Result<ImageBackground, String> {
    match value {
        "terminal" => Ok(ImageBackground::Terminal),
        "theme" => {
            let rgb = match palette.background {
                Color::Rgb(r, g, b) => [r, g, b],
                _ => [0, 0, 0],
            };
            Ok(ImageBackground::Rgb(rgb))
        }
        hex => Ok(ImageBackground::Rgb(parse_hex(hex, "--image-background")?)),
    }
}

/// Parse `#rrggbb`, naming the option in any error.
fn parse_hex(value: &str, option: &str) -> Result<[u8; 3], String> {
    let digits = value
        .strip_prefix('#')
        .ok_or_else(|| format!("{option}: expected #rrggbb, got {value}"))?;
    if digits.len() != 6 || !digits.is_ascii() {
        return Err(format!("{option}: expected six hex digits, got {value}"));
    }
    let channel = |start: usize| {
        u8::from_str_radix(&digits[start..start + 2], 16)
            .map_err(|_| format!("{option}: {value} is not a hex colour"))
    };
    Ok([channel(0)?, channel(2)?, channel(4)?])
}

fn read_input(path: Option<&PathBuf>) -> Result<String, String> {
    match path {
        Some(path) => std::fs::read_to_string(path)
            .map_err(|err| format!("could not read {}: {err}", path.display())),
        None => {
            let mut buf = String::new();
            io::stdin()
                .read_to_string(&mut buf)
                .map_err(|err| format!("could not read standard input: {err}"))?;
            Ok(buf)
        }
    }
}

fn write_stdout(json: &str) -> io::Result<()> {
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    out.write_all(json.as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()
}

/// The canonical wire name of a theme.
///
/// The theme's `snake_case` serde name, so the plugin, the CLI and any future
/// config file all spell themes the same way.
fn theme_name(theme: Theme) -> String {
    serde_json::to_value(theme)
        .ok()
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_else(|| "default".to_string())
}

fn parse_theme(name: &str) -> Result<Theme, String> {
    // Hyphens are accepted as well as underscores so that
    // `--theme catppuccin-mocha` works alongside the canonical
    // `catppuccin_mocha`. One spelling is canonical — the serde name, which
    // `--themes` prints — and the other is a courtesy, not a second name to
    // keep in step.
    let normalised = name.replace('-', "_");
    serde_json::from_value(serde_json::Value::String(normalised)).map_err(|_| {
        let names: Vec<String> = Theme::ALL.iter().copied().map(theme_name).collect();
        format!("unknown theme `{name}`; expected one of: {}", names.join(", "))
    })
}
