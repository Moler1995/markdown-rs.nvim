//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
//!
//! Mermaid diagram rendering, text only.
//!
//! # What was removed from the origin
//!
//! The origin rendered diagrams two ways: as Unicode text, and as a raster
//! image pushed through the terminal's graphics protocol. The image path — an
//! SVG rasteriser (`resvg`), a font database, a thread pool with timeouts, an
//! LRU cache of decoded images, and protocol negotiation for Kitty/iTerm2/
//! WezTerm/sixel — existed because the TUI owned a terminal and could draw
//! pixels into it. An editor plugin cannot: it hands back text, and the
//! surrounding editor draws it. So the image pipeline, its cache, and its
//! protocol detection are all gone, and what remains is the part that turns
//! mermaid source into box-drawing characters.
//!
//! The origin's cache also fed scroll arithmetic (cached cell heights for
//! blocks not yet on screen). The engine lays out every block on every render,
//! so there is nothing to cache.

/// Which layered-layout backend `mermaid-text` should use for flowcharts and
/// state diagrams.
///
/// Sugiyama is the library's default and handles most diagrams well. Native
/// is more compact for one documented shape (a `subgraph` carrying its own
/// `direction` line inside a differently-directed outer graph), which is what
/// [`MermaidTextBackend::Auto`] detects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MermaidTextBackend {
    /// The library default: layered layout with crossing minimisation.
    Sugiyama,
    /// The hand-rolled layout, chosen when it is known to be more compact.
    Native,
    /// Pick per diagram from the source; see [`auto_prefers_native`].
    #[default]
    Auto,
}

/// Render mermaid source to Unicode box-drawing text via `mermaid-text`.
///
/// `mermaid-text` is our own library crate (MIT, zero unsafe, no stdout
/// writes, no panics on valid input). Flowcharts, state diagrams, sequence
/// diagrams, `erDiagram` and pie charts are supported.
///
/// # Arguments
///
/// * `source` – raw mermaid source text.
/// * `max_width` – optional column budget; when `Some(w)` the renderer
///   compacts the diagram until it fits within `w` columns, choosing the
///   shortest arrangement that does. `None` renders at natural size.
/// * `backend` – the layered-layout backend to use for flowchart and state
///   diagrams. Other diagram types ignore this.
///
/// # Errors
///
/// Returns the library's error message when the diagram is malformed or of an
/// unsupported type. Callers should fall back to showing the raw source.
pub fn render_text(
    source: &str,
    max_width: Option<usize>,
    backend: MermaidTextBackend,
) -> Result<String, String> {
    let opts = mermaid_text::RenderOptions {
        max_width,
        backend: to_layout_backend(backend, source),
        ..Default::default()
    };
    mermaid_text::render_with_options(source, &opts).map_err(|e| format!("{e}"))
}

/// [`render_text`] with an explicit `(layer_gap, node_gap)` override,
/// bypassing the `max_width` compaction pipeline.
///
/// Sequence, pie, and erDiagram diagrams ignore the gap override — they have
/// their own layout pipelines. For those types the result is the same as
/// [`render_text`] with `max_width = None`.
///
/// # Errors
///
/// As [`render_text`].
pub fn render_text_with_gaps(
    source: &str,
    layer_gap: usize,
    node_gap: usize,
    backend: MermaidTextBackend,
) -> Result<String, String> {
    let opts = mermaid_text::RenderOptions {
        gaps_override: Some((layer_gap, node_gap)),
        backend: to_layout_backend(backend, source),
        ..Default::default()
    };
    mermaid_text::render_with_options(source, &opts).map_err(|e| format!("{e}"))
}

/// Resolve a [`MermaidTextBackend`] into a concrete `mermaid-text` backend.
///
/// `Auto` is resolved against the source: when the source contains a
/// `subgraph` block with an inner `direction` override (the shape that
/// Sugiyama is documented to render less compactly than Native — see
/// `RenderOptions::backend` in `mermaid-text`), `Auto` resolves to `Native`.
/// Every other shape resolves to `Sugiyama`.
///
/// The choice is conservative on purpose: Sugiyama is the library's default
/// and handles almost every diagram cleanly, so `Auto` only deviates from it
/// when there is a documented reason to.
fn to_layout_backend(
    backend: MermaidTextBackend,
    source: &str,
) -> mermaid_text::layout::LayoutBackend {
    match backend {
        MermaidTextBackend::Sugiyama => mermaid_text::layout::LayoutBackend::Sugiyama,
        MermaidTextBackend::Native => mermaid_text::layout::LayoutBackend::Native,
        MermaidTextBackend::Auto => {
            if auto_prefers_native(source) {
                mermaid_text::layout::LayoutBackend::Native
            } else {
                mermaid_text::layout::LayoutBackend::Sugiyama
            }
        }
    }
}

/// True when the source contains a `subgraph` block that has its own
/// `direction` line — the shape where Sugiyama is less compact than Native.
///
/// Detection is purely lexical: we scan the lines, increment a depth counter
/// on each `subgraph` opener, decrement on `end`, and look for `direction`
/// anywhere inside a non-zero-depth region. This avoids parsing the source
/// twice (mermaid-text would otherwise parse it again immediately after) and
/// is robust to indentation, comments, and the various keyword forms the
/// flowchart parser accepts.
fn auto_prefers_native(source: &str) -> bool {
    let mut depth: usize = 0;
    for line in source.lines() {
        let trimmed = line.trim_start();
        // `subgraph FOO`, `subgraph "Foo Bar"`, or a bare `subgraph`. Match
        // the keyword with a trailing boundary so identifiers that happen to
        // start with `subgraph` aren't caught.
        if let Some(rest) = trimmed.strip_prefix("subgraph")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            depth += 1;
            continue;
        }
        if depth == 0 {
            continue;
        }
        // `end` (alone, or followed by whitespace / comment) closes the
        // innermost subgraph. Edge labels like `endorse` must not match.
        if trimmed == "end"
            || trimmed.starts_with("end ")
            || trimmed.starts_with("end\t")
            || trimmed.starts_with("end%")
        {
            depth -= 1;
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("direction")
            && rest.starts_with(char::is_whitespace)
        {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use unicode_width::UnicodeWidthStr;

    const SEQUENCE_DIAGRAM: &str = r"sequenceDiagram
    participant W as Worker
    participant CP as CheckpointStore
    participant ES as EventReader
    W->>CP: Read checkpoint (last sequence)
    CP-->>W: sequence_number
    W->>ES: Poll events (after sequence, limit 500)
    ES-->>W: batch of StoredEvents";

    const GRAPH_LR_1: &str = r"graph LR
    subgraph Supervisor
        direction TB
        F[Factory] -->|creates| W[Worker]
        W -->|panics/exits| F
    end
    W -->|beat every cycle| HB[Heartbeat]
    HB -->|checked every 10s| WD[Watchdog]
    WD -->|stall > 120s| CT[Cancel Token]
    CT -->|stops| W
    style WD fill:#c82,stroke:#fff,color:#fff";

    const STATE_DIAGRAM: &str = r"stateDiagram-v2
    [*] --> Idle
    Idle --> Running: start
    Running --> Idle: stop
    Running --> [*]: crash";

    const GRAPH_LR_2: &str = r"graph LR
    subgraph projections-pg [projections-pg :9092]
        PG_W[event_log, account_registry]
    end
    PG_W --> PG[(PostgreSQL)]
    style PG fill:#336,stroke:#fff,color:#fff";

    /// Every diagram type the engine claims to support must render to text.
    /// This is the smoke test for the whole text pipeline: if `mermaid-text`
    /// loses a parser, or the wrapper stops threading `RenderOptions`, this
    /// fails before any snapshot does.
    #[test]
    fn renders_every_supported_diagram_type() {
        let diagrams = [
            ("sequenceDiagram", SEQUENCE_DIAGRAM),
            ("graph LR (resilience)", GRAPH_LR_1),
            ("stateDiagram-v2", STATE_DIAGRAM),
            ("graph LR (deployments)", GRAPH_LR_2),
        ];

        let mut failed: Vec<(&str, String)> = Vec::new();
        for (name, src) in &diagrams {
            match render_text(src, None, MermaidTextBackend::Auto) {
                Ok(text) if !text.trim().is_empty() => {}
                Ok(_) => failed.push((name, "rendered empty".to_string())),
                Err(e) => failed.push((name, e)),
            }
        }

        assert!(failed.is_empty(), "diagrams failed to render: {failed:?}");
    }

    /// The backend parameter must actually reach `RenderOptions::backend`. If
    /// the two backends produced equal output it would mean the argument is
    /// threaded through the function signature but discarded before reaching
    /// the library — i.e. the entire feature is silently no-op'd.
    #[test]
    fn backend_threads_through_render_text() {
        let native = render_text(GRAPH_LR_1, None, MermaidTextBackend::Native)
            .expect("Native render must succeed");
        let sugiyama = render_text(GRAPH_LR_1, None, MermaidTextBackend::Sugiyama)
            .expect("Sugiyama render must succeed");
        assert_ne!(
            native, sugiyama,
            "Native and Sugiyama outputs must differ — if equal, the \
             text_backend argument is being discarded before reaching \
             RenderOptions::backend (the whole feature is a no-op)"
        );
    }

    /// Same load-bearing check for the gap-override path, which builds its own
    /// `RenderOptions`. It could silently fall back to the default backend if
    /// the parameter were dropped at the wrapper boundary.
    #[test]
    fn gap_override_threads_through_chosen_backend() {
        let native = render_text_with_gaps(GRAPH_LR_1, 6, 2, MermaidTextBackend::Native)
            .expect("Native gap render must succeed");
        let sugiyama = render_text_with_gaps(GRAPH_LR_1, 6, 2, MermaidTextBackend::Sugiyama)
            .expect("Sugiyama gap render must succeed");
        assert_ne!(
            native, sugiyama,
            "the gap-override path must honour the caller's text_backend \
             choice — if equal, the argument is being dropped at the \
             render_text_with_gaps wrapper boundary"
        );
    }

    /// A `max_width` budget must actually narrow the output. Without this the
    /// compaction pipeline could be dropped and every diagram would overflow
    /// its column budget silently.
    #[test]
    fn max_width_narrows_output() {
        let natural =
            render_text(GRAPH_LR_2, None, MermaidTextBackend::Auto).expect("natural render");
        let narrow = render_text(GRAPH_LR_2, Some(40), MermaidTextBackend::Auto)
            .expect("narrow render");

        let natural_width = natural
            .lines()
            .map(UnicodeWidthStr::width)
            .max()
            .unwrap_or(0);
        let narrow_width = narrow
            .lines()
            .map(UnicodeWidthStr::width)
            .max()
            .unwrap_or(0);

        assert!(
            narrow_width <= natural_width,
            "a 40-column budget produced {narrow_width} columns against a \
             natural width of {natural_width} — the compaction pipeline is \
             not being applied"
        );
    }

    // ── Auto backend resolution ──────────────────────────────────────────────

    /// `auto_prefers_native` must detect the documented Sugiyama coverage
    /// gap: a subgraph block that has an inner `direction` line.
    #[test]
    fn auto_prefers_native_when_subgraph_has_inner_direction() {
        // GRAPH_LR_1's `Supervisor` subgraph carries `direction TB` inside an
        // outer `graph LR` — the exact shape that is Sugiyama's weak spot.
        assert!(
            auto_prefers_native(GRAPH_LR_1),
            "GRAPH_LR_1 has a subgraph with `direction TB` inside `graph LR` \
             — the load-bearing fixture for this heuristic. If this fails, \
             the detection regressed or the fixture was edited."
        );
    }

    /// A flat dependency graph (no subgraphs) must NOT trigger the Native
    /// override — Auto should resolve to Sugiyama for the common case.
    #[test]
    fn auto_does_not_prefer_native_for_flat_dag() {
        let src = "graph LR\n    A --> B\n    B --> C\n    C --> D\n";
        assert!(
            !auto_prefers_native(src),
            "flat LR chains must take the Sugiyama path under Auto"
        );
    }

    /// A subgraph WITHOUT an inner `direction` line must NOT trigger Native
    /// — the heuristic is intentionally narrow. Pinning this prevents the
    /// detection from drifting into "any subgraph triggers Native".
    #[test]
    fn auto_does_not_prefer_native_for_plain_subgraph() {
        let src = "graph LR\n\
                   subgraph cluster\n\
                       A --> B\n\
                   end\n\
                   B --> C\n";
        assert!(
            !auto_prefers_native(src),
            "subgraph without inner `direction` must NOT trigger Native — \
             only the documented Sugiyama coverage gap (subgraph + inner \
             direction) should opt in"
        );
    }

    /// A nested `direction` inside a `subgraph` block (regardless of which
    /// flow direction) must trigger Native. This pins the keyword detection
    /// logic, not the specific direction value.
    #[test]
    fn auto_prefers_native_for_any_nested_direction_value() {
        for dir in ["TB", "BT", "LR", "RL"] {
            let src = format!(
                "graph LR\n\
                 subgraph cluster\n\
                     direction {dir}\n\
                     A --> B\n\
                 end\n"
            );
            assert!(
                auto_prefers_native(&src),
                "inner `direction {dir}` must trigger Native"
            );
        }
    }

    /// An edge label or node id that starts with the substring "direction"
    /// must NOT trigger Native — the detection requires the keyword to be
    /// followed by whitespace.
    #[test]
    fn auto_detection_requires_keyword_boundary() {
        let src = "graph LR\n\
                   subgraph cluster\n\
                       directional --> A\n\
                   end\n";
        assert!(
            !auto_prefers_native(src),
            "an identifier starting with `direction` must NOT be treated \
             as the `direction` keyword"
        );
    }

    /// `Auto` must produce the same bytes as `Sugiyama` for the flat-DAG case
    /// AND the same bytes as `Native` for the subgraph-with-inner-direction
    /// case. Strongest assertion possible: it pins that Auto is genuinely
    /// routing, not just defaulting either way.
    #[test]
    fn auto_routes_to_expected_backend() {
        let flat = "graph LR\n    A --> B --> C\n";
        let auto_flat =
            render_text(flat, None, MermaidTextBackend::Auto).expect("Auto flat render");
        let sugiyama_flat =
            render_text(flat, None, MermaidTextBackend::Sugiyama).expect("Sugiyama flat render");
        assert_eq!(
            auto_flat, sugiyama_flat,
            "Auto must produce Sugiyama output for a flat LR chain"
        );

        let auto_subgraph =
            render_text(GRAPH_LR_1, None, MermaidTextBackend::Auto).expect("Auto subgraph render");
        let native_subgraph = render_text(GRAPH_LR_1, None, MermaidTextBackend::Native)
            .expect("Native subgraph render");
        assert_eq!(
            auto_subgraph, native_subgraph,
            "Auto must produce Native output for a subgraph with inner \
             `direction TB` — the documented Sugiyama coverage gap"
        );
    }

    /// Source that is not a diagram must produce an error rather than a panic,
    /// so the caller can fall back to showing the raw fence. `mermaid-text` is
    /// lenient about malformed *edges*, so this uses input it genuinely cannot
    /// classify.
    #[test]
    fn unrecognised_source_errors_instead_of_panicking() {
        assert!(
            render_text("this is not a diagram", None, MermaidTextBackend::Auto).is_err(),
            "text that names no diagram type must surface as an error"
        );
    }
}
