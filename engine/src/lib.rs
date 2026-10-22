//! `md-render` — a markdown-to-styled-lines engine.
//!
//! The crate renders a markdown document into a flat list of styled display
//! lines sized to a requested column width, plus the mapping between those
//! lines and the source lines they came from. It is deliberately unaware of
//! any editor: it takes text and a width and returns data, and the Neovim
//! plugin in `lua/md-render/` is one consumer of that data.
//!
//! # The pipeline
//!
//! ```text
//!   source ──▶ renderer ──▶ [DocBlock] ──▶ document ──▶ WireDoc ──▶ JSON
//!              (parse)      (structure)     (layout)     (wire)
//! ```
//!
//! * [`renderer`] walks pulldown-cmark events and groups the result into
//!   [`block::DocBlock`] values — text runs, tables, diagrams.
//! * [`document`] lays those blocks out at a target width and produces a
//!   [`wire::WireDoc`].
//! * [`wire`] is the serialisable shape the plugin reads.
//!
//! # Width
//!
//! Every line the engine emits fits the requested width. That is enforced in
//! one place — [`document`] — rather than trusted to each renderer, because
//! diagram artwork in particular is laid out by best-effort compaction rather
//! than by a hard constraint.
//!
//! # Provenance
//!
//! The rendering pipeline was ported from the `markdown-reader` TUI
//! (revision 4f0f635, 2026-10-14, MIT, (c) leboiko). Ported modules carry a
//! header naming their origin. The TUI's own concerns — terminal drawing,
//! image protocols, scroll arithmetic, cursor hit-testing — were left behind;
//! see each module's header for what was dropped and why.

pub mod block;
pub mod cast;
pub mod document;
pub mod highlight;
pub mod image_art;
pub mod math;
pub mod mermaid;
pub mod renderer;
pub mod style;
pub mod table;
pub mod text_layout;
pub mod theme;
pub mod wire;

pub use document::layout_document;
pub use renderer::render_markdown;
pub use wire::{WIRE_VERSION, WireDoc};
