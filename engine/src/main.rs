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
    let blocks = render_markdown(&content, &palette, theme);
    let doc = layout_document(&blocks, width, &palette, source_line_count(&content));

    serde_json::to_string(&doc).map_err(|err| format!("could not serialise the document: {err}"))
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
