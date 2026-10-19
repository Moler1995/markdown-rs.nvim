//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
//!
//! Theme system: themes, palettes, semantic tokens, spacing scale.
//!
//! Architecture (Ship 2 of the design-token rollout):
//!
//! * [`Tokens`] is the **source of truth** for each theme. Theme bodies
//!   live in [`themes`]; one `fn` per [`Theme`] variant returns a
//!   fully-derived `Tokens`.
//! * [`Palette`] is a **derived view** auto-generated from `Tokens`
//!   via `From<Tokens>`. Existing callers continue to read
//!   `palette.foreground` etc. unchanged. New callers can opt into
//!   the semantic accessors (`tokens.text.primary`, `tokens.state.focus`).
//! * [`Spacing`] gives a small density scale that retires scattered
//!   `Constraint::Length(N)` magic numbers in `src/ui/`.
//! * [`contrast`] provides the WCAG audit (Ship 1) and the
//!   [`contrast::ColorOps`] arithmetic primitive (Ship 2).
//!
//! Adding a new theme: extend the [`Theme`] enum, add a constructor
//! `fn` in [`themes`], and dispatch in [`Tokens::from_theme`]. The
//! audit tests in [`contrast`] and [`tokens`] run automatically over
//! all variants.

mod contrast;
mod spacing;
mod themes;
mod tokens;

pub use spacing::Spacing;
pub use tokens::Tokens;

// Sub-types (`Surface`, `Text`, `State`, …) and `ColorOps` are intentionally
// not re-exported at this level. Field access via `tokens.text.primary`
// covers the typical caller; the few sites that need to name a sub-type
// can import it directly from `crate::theme::tokens` / `crate::theme::contrast`.
// Ship 2 doesn't migrate any caller off `Palette`, so the sub-types are
// dead at the bin level today.

use crate::style::{Color, Modifier, Style};
use serde::{Deserialize, Serialize};

/// Selectable color themes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    #[default]
    Default,
    Dracula,
    SolarizedDark,
    SolarizedLight,
    Nord,
    GruvboxDark,
    GruvboxLight,
    GithubLight,
    CatppuccinMocha,
}

impl Theme {
    /// All selectable themes in display order.
    pub const ALL: &'static [Theme] = &[
        Theme::Default,
        Theme::Dracula,
        Theme::SolarizedDark,
        Theme::SolarizedLight,
        Theme::Nord,
        Theme::GruvboxDark,
        Theme::GruvboxLight,
        Theme::GithubLight,
        Theme::CatppuccinMocha,
    ];

    /// Human-readable display name for the theme.
    pub fn label(self) -> &'static str {
        match self {
            Theme::Default => "Default",
            Theme::Dracula => "Dracula",
            Theme::SolarizedDark => "Solarized Dark",
            Theme::SolarizedLight => "Solarized Light",
            Theme::Nord => "Nord",
            Theme::GruvboxDark => "Gruvbox Dark",
            Theme::GruvboxLight => "Gruvbox Light",
            Theme::GithubLight => "GitHub Light",
            Theme::CatppuccinMocha => "Catppuccin Mocha",
        }
    }

    /// Name of the bundled syntect theme to use for syntax highlighting when
    /// this UI theme is active.
    ///
    /// The returned string is always a key present in
    /// [`syntect::highlighting::ThemeSet::load_defaults`]'s output:
    /// - `"base16-ocean.dark"`
    /// - `"base16-eighties.dark"`
    /// - `"InspiredGitHub"`
    ///
    /// The exhaustive match (no `_` wildcard) ensures the compiler forces an
    /// update here whenever a new [`Theme`] variant is added.
    pub fn syntax_theme_name(self) -> &'static str {
        match self {
            Theme::Default | Theme::SolarizedDark | Theme::Nord => "base16-ocean.dark",
            Theme::Dracula | Theme::GruvboxDark | Theme::CatppuccinMocha => "base16-eighties.dark",
            Theme::SolarizedLight | Theme::GruvboxLight | Theme::GithubLight => "InspiredGitHub",
        }
    }
}

/// Concrete color values for one theme, threaded through every renderer.
///
/// `Palette` is **auto-generated from [`Tokens`]** via `From<Tokens>` —
/// every field maps mechanically to a token slot. This keeps existing
/// callers (`palette.foreground` etc.) working unchanged while letting
/// the design-token layer enforce invariants and derivation rules at
/// theme construction time.
///
/// Adding a field here requires extending `Tokens` first; the
/// `From<Tokens>` impl will fail to compile until the new mapping is
/// written, which guarantees no field is ever silently uninitialised.
// Several fields are now only populated (not read) at the binary level —
// their readers migrated to `Tokens` slots in Ship 2 follow-up D. The fields
// stay in the struct so the `From<Tokens>` exhaustiveness check keeps compiling
// and tests that compare palette values continue to work. A future ship deletes
// `Palette` entirely once all callers have moved off it.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy)]
pub struct Palette {
    pub background: Color,
    pub foreground: Color,
    pub dim: Color,
    pub border: Color,
    pub border_focused: Color,
    pub accent: Color,
    pub accent_alt: Color,
    pub selection_bg: Color,
    pub selection_fg: Color,
    /// Foreground color for text rendered on an `accent`-colored background.
    ///
    /// For most themes `selection_fg` happens to contrast adequately with
    /// `accent`, so they share the same value. GitHub Light is the exception:
    /// its `selection_fg` is `#0969da` (same as `accent`), which would produce
    /// invisible blue-on-blue text. Setting this field to white for that theme
    /// ensures readable text on the vivid blue accent background.
    pub on_accent_fg: Color,
    pub title: Color,
    pub h1: Color,
    pub h2: Color,
    pub h3: Color,
    pub heading_other: Color,
    pub inline_code: Color,
    pub code_fg: Color,
    pub code_bg: Color,
    pub code_border: Color,
    pub link: Color,
    pub list_marker: Color,
    pub task_marker: Color,
    pub block_quote_fg: Color,
    pub block_quote_border: Color,
    pub table_header: Color,
    pub table_border: Color,
    pub search_match_bg: Color,
    pub current_match_bg: Color,
    pub match_fg: Color,
    pub gutter: Color,
    pub status_bar_bg: Color,
    pub status_bar_fg: Color,
    pub help_bg: Color,
    pub git_new: Color,
    pub git_modified: Color,
}

impl From<Tokens> for Palette {
    fn from(t: Tokens) -> Self {
        Palette {
            background: t.surface.base,
            foreground: t.text.primary,
            dim: t.text.muted,
            border: t.surface.border,
            border_focused: t.state.focus,
            accent: t.accent.primary,
            accent_alt: t.accent.alt,
            selection_bg: t.state.selection_bg,
            selection_fg: t.state.selection_fg,
            on_accent_fg: t.text.on_accent,
            title: t.text.title,
            h1: t.heading.h1,
            h2: t.heading.h2,
            h3: t.heading.h3,
            heading_other: t.heading.other,
            inline_code: t.syntax.inline_code,
            code_fg: t.syntax.code_fg,
            // `code_bg` sources from the surface tier — see `Syntax` doc.
            code_bg: t.surface.raised,
            code_border: t.syntax.code_border,
            link: t.accent.link,
            list_marker: t.list.marker,
            task_marker: t.list.task_marker,
            block_quote_fg: t.list.block_quote_fg,
            block_quote_border: t.list.block_quote_border,
            table_header: t.table.header,
            table_border: t.table.border,
            search_match_bg: t.state.search_bg,
            current_match_bg: t.state.current_match_bg,
            match_fg: t.state.match_fg,
            gutter: t.status.gutter,
            status_bar_bg: t.status.bg,
            status_bar_fg: t.status.fg,
            help_bg: t.status.help_bg,
            git_new: t.git.new,
            git_modified: t.git.modified,
        }
    }
}

impl Palette {
    /// Construct the color palette for the given theme.
    #[must_use]
    pub fn from_theme(theme: Theme) -> Self {
        Tokens::from_theme(theme).into()
    }

    /// Style for unfocused panel borders.
    pub fn border_style(self) -> Style {
        Style::new().fg(self.border)
    }

    /// Style for focused panel borders.
    pub fn border_focused_style(self) -> Style {
        Style::new().fg(self.border_focused)
    }

    /// Bold style for widget titles.
    pub fn title_style(self) -> Style {
        Style::new().fg(self.title).add_modifier(Modifier::BOLD)
    }

    /// Style for the currently selected list item.
    pub fn selected_style(self) -> Style {
        Style::new()
            .bg(self.selection_bg)
            .fg(self.selection_fg)
            .add_modifier(Modifier::BOLD)
    }

    /// Style for de-emphasized (dim) text.
    pub fn dim_style(self) -> Style {
        Style::new().fg(self.dim)
    }
}

impl Default for Palette {
    fn default() -> Self {
        Self::from_theme(Theme::Default)
    }
}

// ── Ship 1 contrast/palette-invariant audit ──────────────────────────────────
//
// These tests run against the auto-generated `Palette` so they continue
// to pin every theme's *shipped* values regardless of whether those
// values came from explicit literals or `Tokens` derivations. New
// per-token invariants (derived selection distinctness, focus
// visibility) live in `tokens::tests`.

#[cfg(test)]
mod tests {
    use super::contrast::contrast_ratio;
    use super::*;

    /// WCAG AA threshold for normal-size text. Smaller text and thin
    /// strokes (e.g. box-drawing borders) want this floor too — sub-AA
    /// is the symptom that triggered the 1.22.4 fix conversation.
    const AA_NORMAL: f64 = 4.5;

    /// Every theme must have `on_accent_fg != accent` so that text drawn on an
    /// accent-coloured background is never invisible.
    #[test]
    fn on_accent_fg_contrasts_with_accent() {
        for &theme in Theme::ALL {
            let p = Palette::from_theme(theme);
            assert_ne!(
                p.on_accent_fg, p.accent,
                "Theme {theme:?}: on_accent_fg == accent — text would be invisible",
            );
        }
    }

    /// Catppuccin Mocha's shipped values, checked against the upstream
    /// palette rather than against whatever the theme constructor happens to
    /// contain. A theme that drifts silently is worse than no theme: the
    /// editor's catppuccin colours and the engine's would disagree on the same
    /// screen, which is exactly the mismatch this theme exists to avoid.
    #[test]
    fn catppuccin_mocha_matches_the_upstream_palette() {
        let p = Palette::from_theme(Theme::CatppuccinMocha);
        let rgb = Color::Rgb;
        for (slot, actual, expected, name) in [
            ("background", p.background, rgb(0x1e, 0x1e, 0x2e), "base"),
            ("foreground", p.foreground, rgb(0xcd, 0xd6, 0xf4), "text"),
            ("dim", p.dim, rgb(0x6c, 0x70, 0x86), "overlay0"),
            ("code_bg", p.code_bg, rgb(0x31, 0x32, 0x44), "surface0"),
            ("border", p.border, rgb(0x45, 0x47, 0x5a), "surface1"),
            ("accent", p.accent, rgb(0xcb, 0xa6, 0xf7), "mauve"),
            ("accent_alt", p.accent_alt, rgb(0xf5, 0xc2, 0xe7), "pink"),
            ("link", p.link, rgb(0x74, 0xc7, 0xec), "sapphire"),
            ("h1", p.h1, rgb(0xf3, 0x8b, 0xa8), "red"),
            ("h2", p.h2, rgb(0xfa, 0xb3, 0x87), "peach"),
            ("h3", p.h3, rgb(0xf9, 0xe2, 0xaf), "yellow"),
            ("inline_code", p.inline_code, rgb(0xa6, 0xe3, 0xa1), "green"),
            ("table_header", p.table_header, rgb(0xb4, 0xbe, 0xfe), "lavender"),
            ("list_marker", p.list_marker, rgb(0x74, 0xc7, 0xec), "sapphire"),
            ("task_marker", p.task_marker, rgb(0xa6, 0xe3, 0xa1), "green"),
            ("git_new", p.git_new, rgb(0xa6, 0xe3, 0xa1), "green"),
            ("git_modified", p.git_modified, rgb(0xf9, 0xe2, 0xaf), "yellow"),
        ] {
            assert_eq!(actual, expected, "catppuccin_mocha {slot} should be {name}");
        }
    }

    /// The new theme must not be a copy of an existing one — a variant that
    /// renders identically is a variant nobody can tell they selected.
    #[test]
    fn catppuccin_mocha_is_distinct_from_the_other_themes() {
        let mocha = Palette::from_theme(Theme::CatppuccinMocha);
        for &theme in Theme::ALL {
            if theme == Theme::CatppuccinMocha {
                continue;
            }
            let other = Palette::from_theme(theme);
            assert_ne!(
                (mocha.background, mocha.accent, mocha.h1),
                (other.background, other.accent, other.h1),
                "catppuccin_mocha renders like {theme:?}",
            );
        }
    }

    /// Selection / cursor highlight backgrounds must differ from the
    /// surfaces they overlay, otherwise the highlight is invisible.
    ///
    /// Reported on solarized_light 2026-04-24: `selection_bg ==
    /// code_bg == Rgb(238, 232, 213)` made the cursor highlight inside
    /// code blocks completely invisible.
    #[test]
    fn highlight_bgs_differ_from_surfaces() {
        let mut failures: Vec<String> = Vec::new();
        for &theme in Theme::ALL {
            let p = Palette::from_theme(theme);
            for (a_name, a, b_name, b) in [
                ("selection_bg", p.selection_bg, "code_bg", p.code_bg),
                ("selection_bg", p.selection_bg, "background", p.background),
                ("current_match_bg", p.current_match_bg, "code_bg", p.code_bg),
                (
                    "current_match_bg",
                    p.current_match_bg,
                    "background",
                    p.background,
                ),
            ] {
                if a == b {
                    failures.push(format!(
                        "  {theme:?}: {a_name} == {b_name} ({a:?}) — highlight invisible",
                    ));
                }
            }
        }
        assert!(
            failures.is_empty(),
            "highlight backgrounds collide with surfaces:\n{}",
            failures.join("\n"),
        );
    }

    /// Reading-text fg/bg pairs must meet WCAG AA contrast for normal
    /// text (≥ 4.5:1). Named colours (terminal-defined RGB) skip
    /// silently — only RGB-defined pairs are asserted.
    #[test]
    fn reading_text_meets_wcag_aa() {
        let mut failures: Vec<String> = Vec::new();
        for &theme in Theme::ALL {
            let p = Palette::from_theme(theme);
            // (label, fg, bg) — pairs the user actually reads as text.
            // Decoration (borders, gutters) is intentionally excluded.
            let pairs: &[(&str, Color, Color)] = &[
                ("foreground/background", p.foreground, p.background),
                ("code_fg/code_bg", p.code_fg, p.code_bg),
                ("selection_fg/selection_bg", p.selection_fg, p.selection_bg),
                ("on_accent_fg/accent", p.on_accent_fg, p.accent),
                ("match_fg/search_match_bg", p.match_fg, p.search_match_bg),
                ("match_fg/current_match_bg", p.match_fg, p.current_match_bg),
                (
                    "status_bar_fg/status_bar_bg",
                    p.status_bar_fg,
                    p.status_bar_bg,
                ),
            ];
            for (name, fg, bg) in pairs {
                if let Some(ratio) = contrast_ratio(*fg, *bg)
                    && ratio < AA_NORMAL
                {
                    failures.push(format!("  {theme:?} {name}: {ratio:.2}:1 < {AA_NORMAL}:1",));
                }
            }
        }
        assert!(
            failures.is_empty(),
            "reading-text pairs fail WCAG AA:\n{}",
            failures.join("\n"),
        );
    }
}
