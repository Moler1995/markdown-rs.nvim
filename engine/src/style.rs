//! The engine's display types.
//!
//! These mirror the shape of the `ratatui` text types the render pipeline was
//! written against, so the ported logic could be carried over in structure
//! rather than rewritten around a different data model. Nothing here draws:
//! a colour is three bytes, a style is a small struct, a span is text plus a
//! style. The engine's only reason to have them is to describe what a reader
//! should see; how it is painted is the caller's business.
//!
//! This module is new code. The `ratatui` types it stands in for are not
//! ported — they are the API the origin's pipeline happened to be written
//! against. The slice of that API the pipeline actually used turned out to be
//! small (no `Stylize` calls, no `Alignment`, no layout or buffer types), so
//! reimplementing it here was cheaper and clearer than rewriting every ported
//! call site around a different data model.

/// A colour, either absolute or one of the terminal's sixteen.
///
/// The named variants exist because the ported theme data is written in terms
/// of them. They mean "whatever the caller's palette says this name is".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Color {
    /// No colour: leave whatever the caller already has in place.
    #[default]
    Reset,
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    Gray,
    DarkGray,
    LightRed,
    LightGreen,
    LightYellow,
    LightBlue,
    LightMagenta,
    LightCyan,
    White,
    Rgb(u8, u8, u8),
    Indexed(u8),
}

/// A set of text attributes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Modifier(u16);

impl Modifier {
    pub const BOLD: Modifier = Modifier(1 << 0);
    pub const DIM: Modifier = Modifier(1 << 1);
    pub const ITALIC: Modifier = Modifier(1 << 2);
    pub const UNDERLINED: Modifier = Modifier(1 << 3);
    pub const CROSSED_OUT: Modifier = Modifier(1 << 4);
    pub const REVERSED: Modifier = Modifier(1 << 5);

    /// The empty set.
    #[must_use]
    pub const fn empty() -> Modifier {
        Modifier(0)
    }

    /// Every attribute this type can express.
    #[must_use]
    pub const fn all() -> Modifier {
        Modifier(0b11_1111)
    }

    /// True when no attribute is set.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// True when every attribute in `other` is also in `self`.
    #[must_use]
    pub const fn contains(self, other: Modifier) -> bool {
        (self.0 & other.0) == other.0
    }

    /// The union of two sets.
    #[must_use]
    pub const fn union(self, other: Modifier) -> Modifier {
        Modifier(self.0 | other.0)
    }

    /// `self` without the attributes in `other`.
    #[must_use]
    pub const fn difference(self, other: Modifier) -> Modifier {
        Modifier(self.0 & !other.0)
    }
}

/// How a run of text should be displayed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Style {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    pub modifiers: Modifier,
}

impl Style {
    /// The default style: no colours, no attributes.
    #[must_use]
    pub const fn new() -> Style {
        Style {
            fg: None,
            bg: None,
            modifiers: Modifier::empty(),
        }
    }

    /// Set the foreground colour.
    #[must_use]
    pub const fn fg(mut self, color: Color) -> Style {
        self.fg = Some(color);
        self
    }

    /// Set the background colour.
    #[must_use]
    pub const fn bg(mut self, color: Color) -> Style {
        self.bg = Some(color);
        self
    }

    /// Add attributes to this style.
    #[must_use]
    pub const fn add_modifier(mut self, modifier: Modifier) -> Style {
        self.modifiers = self.modifiers.union(modifier);
        self
    }

    /// Remove attributes from this style.
    #[must_use]
    pub const fn remove_modifier(mut self, modifier: Modifier) -> Style {
        self.modifiers = self.modifiers.difference(modifier);
        self
    }

    /// True when every attribute in `modifier` is set.
    #[must_use]
    pub const fn has_modifier(self, modifier: Modifier) -> bool {
        self.modifiers.contains(modifier)
    }

    /// Overlay `other` on top of `self`: every field `other` sets wins.
    ///
    /// This is how the renderer's style stack composes — a heading pushes a
    /// foreground and bold, and the pop restores what was underneath.
    #[must_use]
    pub fn patch(mut self, other: Style) -> Style {
        if other.fg.is_some() {
            self.fg = other.fg;
        }
        if other.bg.is_some() {
            self.bg = other.bg;
        }
        self.modifiers = self.modifiers.union(other.modifiers);
        self
    }
}

/// A run of text sharing one style.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Span {
    pub content: String,
    pub style: Style,
}

impl Span {
    /// A span in the default style.
    #[must_use]
    pub fn raw(content: impl Into<String>) -> Span {
        Span {
            content: content.into(),
            style: Style::new(),
        }
    }

    /// A span with an explicit style.
    #[must_use]
    pub fn styled(content: impl Into<String>, style: Style) -> Span {
        Span {
            content: content.into(),
            style,
        }
    }
}

/// One display line: an ordered sequence of spans.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Line {
    pub spans: Vec<Span>,
}

impl Line {
    /// An empty line.
    #[must_use]
    pub fn new() -> Line {
        Line { spans: Vec::new() }
    }

    /// The concatenated text of every span, ignoring style.
    #[must_use]
    pub fn text(&self) -> String {
        self.spans.iter().map(|s| s.content.as_str()).collect()
    }

    /// The display width of the line in columns.
    #[must_use]
    pub fn width(&self) -> usize {
        self.spans
            .iter()
            .map(|s| unicode_width::UnicodeWidthStr::width(s.content.as_str()))
            .sum()
    }
}

impl From<&str> for Line {
    fn from(value: &str) -> Line {
        if value.is_empty() {
            Line::new()
        } else {
            Line {
                spans: vec![Span::raw(value)],
            }
        }
    }
}

impl From<String> for Line {
    fn from(value: String) -> Line {
        if value.is_empty() {
            Line::new()
        } else {
            Line {
                spans: vec![Span::raw(value)],
            }
        }
    }
}

impl From<Span> for Line {
    fn from(value: Span) -> Line {
        Line { spans: vec![value] }
    }
}

impl From<Vec<Span>> for Line {
    fn from(spans: Vec<Span>) -> Line {
        Line { spans }
    }
}

/// A sequence of display lines.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Text {
    pub lines: Vec<Line>,
}

impl Text {
    /// An empty document fragment.
    #[must_use]
    pub fn new() -> Text {
        Text { lines: Vec::new() }
    }
}

impl From<Vec<Line>> for Text {
    fn from(lines: Vec<Line>) -> Text {
        Text { lines }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_default_colour_is_distinct_from_the_named_ones() {
        // `Reset` means "leave the caller's colour alone" and must not be
        // confused with a colour that happens to look like the terminal's
        // default.
        assert_eq!(Color::default(), Color::Reset);
        assert_ne!(Color::Reset, Color::Gray);
    }

    #[test]
    fn absolute_colours_keep_their_components() {
        assert_eq!(Color::Rgb(0x12, 0x34, 0x56), Color::Rgb(0x12, 0x34, 0x56));
        assert_ne!(Color::Rgb(0x12, 0x34, 0x56), Color::Rgb(0x12, 0x34, 0x57));
        assert_ne!(Color::Indexed(1), Color::Indexed(2));
        // An indexed colour is not the named colour that shares its slot: one
        // is resolved by the caller's palette, the other by the terminal.
        assert_ne!(Color::Indexed(1), Color::Red);
    }

    #[test]
    fn a_style_can_combine_several_modifiers() {
        let style = Style::new()
            .add_modifier(Modifier::BOLD)
            .add_modifier(Modifier::ITALIC);
        assert!(style.has_modifier(Modifier::BOLD));
        assert!(style.has_modifier(Modifier::ITALIC));
        assert!(style.has_modifier(Modifier::BOLD.union(Modifier::ITALIC)));
        assert!(!style.has_modifier(Modifier::UNDERLINED));

        let style = style.remove_modifier(Modifier::BOLD);
        assert!(!style.has_modifier(Modifier::BOLD));
        assert!(style.has_modifier(Modifier::ITALIC));
    }

    #[test]
    fn an_empty_modifier_set_has_nothing_set() {
        assert!(Modifier::empty().is_empty());
        assert!(!Modifier::BOLD.is_empty());
        assert!(Modifier::all().contains(Modifier::BOLD.union(Modifier::REVERSED)));
    }

    #[test]
    fn patch_lets_the_overlay_win_and_keeps_what_it_leaves_unset() {
        let base = Style::new()
            .fg(Color::Red)
            .bg(Color::Black)
            .add_modifier(Modifier::BOLD);
        // The overlay sets a foreground and italic, and says nothing about the
        // background — which is the point: an unset field must not clear.
        let patched = base.patch(Style::new().fg(Color::Blue).add_modifier(Modifier::ITALIC));

        assert_eq!(patched.fg, Some(Color::Blue));
        assert_eq!(patched.bg, Some(Color::Black));
        assert!(patched.has_modifier(Modifier::BOLD));
        assert!(patched.has_modifier(Modifier::ITALIC));
    }

    #[test]
    fn a_line_measures_its_columns_not_its_bytes() {
        let line = Line::from(vec![
            Span::raw("ab"),
            Span::styled("中", Style::new().fg(Color::Rgb(1, 2, 3))),
        ]);
        assert_eq!(line.text(), "ab中");
        // Three characters, four columns, five bytes: neither the byte length
        // nor the character count is the number a layout cares about.
        assert_eq!(line.width(), 4);
        assert_eq!(line.text().chars().count(), 3);
        assert_eq!(line.text().len(), 5);
    }

    #[test]
    fn an_empty_string_makes_an_empty_line_not_a_span_of_nothing() {
        // A span holding "" would still be a span, and the wire format would
        // emit a zero-length entry for it.
        assert!(Line::from("").spans.is_empty());
        assert!(Line::from(String::new()).spans.is_empty());
        assert_eq!(Line::from("x").spans.len(), 1);
    }
}
