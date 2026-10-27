//! `md-render` — render a markdown document to the wire format on stdout.
//!
//! ```text
//! md-render --width 120 --theme nord path/to/file.md
//! cat file.md | md-render --width 120
//! md-render thumbnail art.png --box 80x24 --out thumb --background '#1e1e1e'
//! md-render thumbnail art.png --box 80x24 --crop 4x12 --out part --background '#1e1e1e'
//! ```
//!
//! The width is required. There is no sensible default: the engine lays out
//! tables and diagrams against a column budget, and a guess would produce
//! output the caller then has to discard. Making it mandatory means a caller
//! that forgets it gets an error rather than a subtly wrong render.
//!
//! The one auxiliary mode is `thumbnail`: it writes a picture for the plugin
//! to paint inline instead of a document, and takes no width.

use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use md_render::document::{layout_document, source_line_count};
use md_render::image_art::{
    CardColours, DitherMode, ImageBackground, ImageEncoding, ImageOptions, ImagePalette,
    ThumbnailFormat,
};
use md_render::renderer::render_markdown;
use md_render::style::Color;
use md_render::theme::{Palette, Theme};

/// Render markdown to styled display lines.
#[derive(Debug, Parser)]
#[command(
    name = "md-render",
    version,
    about,
    long_about = None,
    // `thumbnail` must win over the render path positional of the same name,
    // and a subcommand carries its own required set.
    subcommand_precedence_over_arg = true,
    subcommand_negates_reqs = true,
    args_conflicts_with_subcommands = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[command(flatten)]
    render: RenderArgs,
}

/// The auxiliary modes, each of which exits without writing a document.
#[derive(Debug, Subcommand)]
enum Command {
    /// Encode a picture for a cell box, for the plugin to paint inline.
    Thumbnail(ThumbnailArgs),
}

/// Encode a picture at the shape a terminal cell box has.
#[derive(Debug, Args)]
struct ThumbnailArgs {
    /// Image file to encode.
    source: PathBuf,

    /// Cell box the picture is painted into, as `COLSxROWS`.
    ///
    /// The output's proportions are the artwork's own: `cols` to twice `rows`.
    #[arg(long = "box", value_name = "COLSxROWS", value_parser = parse_box)]
    cells: (u16, u16),

    /// File to write the encoded picture to.
    #[arg(long, value_name = "PATH")]
    out: PathBuf,

    /// Part of the box to encode, as `TOPxROWS`.
    ///
    /// The picture is fitted and centred in the whole box first, and the rows
    /// are cut from that drawing, so the output is the same picture at the
    /// same scale as the whole box. A block half-scrolled out of the window
    /// asks for the rows still on screen.
    #[arg(long, value_name = "TOPxROWS", value_parser = parse_crop)]
    crop: Option<(u16, u16)>,

    /// Colour filling the band the picture does not cover, as `#rrggbb`.
    #[arg(long, value_name = "#rrggbb", value_parser = parse_background_hex)]
    background: [u8; 3],

    /// Format to encode in.
    ///
    /// `auto` writes PNG when the picture has transparent pixels and JPEG
    /// otherwise, which is the smallest encode the terminals decode. `png` is
    /// for the transport that decodes PNG alone; `jpeg` composites the picture
    /// over `--background`, because the format has no alpha channel.
    #[arg(long, value_enum, default_value = "auto", value_name = "auto|png|jpeg")]
    format: ThumbnailFormat,
}

#[derive(Debug, Args)]
struct RenderArgs {
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
    /// characteristic glyph and one colour; `card` draws no pixels at all — a
    /// quiet box carrying the file's name and size, for a reader whose terminal
    /// shows the picture another way; and `off` renders references as their alt
    /// text. A card is as wide as the artwork's box and as tall as it, unless
    /// `--image-card-rows` gives it a height of its own.
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
    #[arg(
        long,
        default_value = "terminal",
        value_name = "terminal|theme|#rrggbb"
    )]
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

    /// The display rows a card occupies.
    ///
    /// Zero (the default) gives a card the artwork's own box, which is what a
    /// caller that paints the picture over the card needs. A positive value
    /// gives every card that height instead: it stays as wide as the artwork's
    /// box, and no taller than the page allows.
    #[arg(long, default_value_t = 0, value_name = "ROWS")]
    image_card_rows: u16,

    /// The narrowest a card may be, in display columns.
    ///
    /// Zero (the default) leaves the card the width of the artwork's box. A
    /// caller with text to write on the card raises it so the card can hold
    /// that text; the requested render width stays the hard bound.
    #[arg(long, default_value_t = 0, value_name = "COLS")]
    image_card_min_width: u16,

    /// Do not write a card's caption.
    ///
    /// A caller that paints the picture over the card wants a surface, not a
    /// placeholder: a picture may be transparent, and a transparent pixel
    /// shows what is underneath it, so a caption there would read as letters
    /// floating in the picture. The card keeps its rows, its columns and its
    /// colours either way.
    #[arg(long)]
    no_image_card_caption: bool,

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

    if let Some(Command::Thumbnail(args)) = &cli.command {
        return match md_render::image_art::thumbnail(
            &args.source,
            args.cells.0,
            args.cells.1,
            args.crop,
            args.background,
            args.format,
            &args.out,
        ) {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => fail(&err),
        };
    }

    let render = &cli.render;
    if render.themes {
        for theme in Theme::ALL {
            println!("{}", theme_name(*theme));
        }
        return ExitCode::SUCCESS;
    }

    match run(render) {
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

fn run(cli: &RenderArgs) -> Result<String, String> {
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
        card_rows: cli.image_card_rows,
        card_min_width: cli.image_card_min_width,
        card_caption: !cli.no_image_card_caption,
        sharpen: cli.image_sharpen,
        paper,
        // Left at its default: the layout fills a card's colours from the
        // selected theme, which it has resolved and this flag set has not.
        card: CardColours::default(),
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

/// Parse `--box COLSxROWS`.
fn parse_box(value: &str) -> Result<(u16, u16), String> {
    parse_cells(value, "--box")
}

/// Parse the thumbnail's `--crop TOPxROWS`.
fn parse_crop(value: &str) -> Result<(u16, u16), String> {
    parse_cells(value, "--crop")
}

/// Parse two counts separated by `x`, naming `option` in any error.
fn parse_cells(value: &str, option: &str) -> Result<(u16, u16), String> {
    let (first, second) = value
        .split_once(['x', 'X'])
        .ok_or_else(|| format!("{option}: expected COUNTSxCOUNTS, got {value}"))?;
    let first = first
        .parse::<u16>()
        .map_err(|_| format!("{option}: {first} is not a count"))?;
    let second = second
        .parse::<u16>()
        .map_err(|_| format!("{option}: {second} is not a count"))?;
    Ok((first, second))
}

/// Parse the thumbnail's `--background #rrggbb`.
fn parse_background_hex(value: &str) -> Result<[u8; 3], String> {
    parse_hex(value, "--background")
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
        format!(
            "unknown theme `{name}`; expected one of: {}",
            names.join(", ")
        )
    })
}
