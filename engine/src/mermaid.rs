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
    render(source, &opts).map(|art| art.text)
}

/// [`render_text`], keeping the clickable runs a `click` directive put on a
/// node's label.
///
/// `mermaid-text` marks a linked label with OSC 8 hyperlink sequences instead
/// of returning the target separately. Stripping those sequences without
/// reading them would throw the target away with them, so the renderer parses
/// them into byte ranges on each line before removing them. That is what lets
/// the plugin follow a node link from the rendered view.
///
/// # Errors
///
/// As [`render_text`].
pub fn render_artwork(
    source: &str,
    max_width: Option<usize>,
    backend: MermaidTextBackend,
) -> Result<MermaidArt, String> {
    let opts = mermaid_text::RenderOptions {
        max_width,
        backend: to_layout_backend(backend, source),
        ..Default::default()
    };
    render(source, &opts)
}

/// Render `source` with `opts` and sanitise the result, keeping link ranges.
fn render(source: &str, opts: &mermaid_text::RenderOptions) -> Result<MermaidArt, String> {
    mermaid_text::render_with_options(source, opts)
        .map(|art| strip_escape_sequences(&art))
        .map_err(|e| format!("{e}"))
}

/// Rendered diagram artwork together with the clickable runs on its lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MermaidArt {
    /// The artwork, with every terminal escape sequence removed.
    pub text: String,
    /// One entry per line of `text`, in `text.lines()` order. Each range is a
    /// half-open byte range into that line's text.
    pub links: Vec<Vec<MermaidLink>>,
}

/// A clickable run of a rendered line: bytes `start..end` of the line.
///
/// Byte offsets rather than display columns because the plugin compares them
/// with an editor cursor's byte column, and because slicing the line in Lua
/// works in bytes too.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MermaidLink {
    pub start: u32,
    pub end: u32,
    pub target: String,
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
    render(source, &opts).map(|art| art.text)
}

/// Remove ANSI escape sequences from rendered artwork, collecting OSC 8 links.
///
/// `mermaid-text` wraps the label of every node named by a `click` directive
/// in OSC 8 hyperlink sequences (`ESC ] 8 ; ; url ESC \ label ESC ] 8 ; ; ESC
/// \`) because its own consumer is a terminal that understands them. This
/// engine's consumer is an editor buffer, which shows the bytes literally: a
/// linked label would read `^[]8;;url^[\L2 Prefill LB^[]8;;^[\`, and — worse —
/// the URL's characters would count as display width in
/// [`crate::document`]'s measurement and clipping, so the diagram would lose
/// real columns and report an inflated `layout_width`.
///
/// The sequences still carry something the wire format wants, though: the URL
/// and the exact run of cells it covered. Each opening sequence starts a range
/// in the *cleaned* line's byte coordinates and each closing one ends it; the
/// escapes themselves are dropped. CSI sequences are dropped too, so a future
/// coloured render cannot leak them either.
fn strip_escape_sequences(art: &str) -> MermaidArt {
    let mut text = String::with_capacity(art.len());
    let mut links: Vec<Vec<MermaidLink>> = Vec::new();
    let mut line_links: Vec<MermaidLink> = Vec::new();
    // Byte offset in `text` where the current line starts.
    let mut line_start = 0usize;
    // `(start, target)` of the OSC 8 run currently open, relative to the line.
    let mut active: Option<(usize, String)> = None;

    let mut chars = art.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\x1b' {
            if ch == '\n' {
                close_link(&mut line_links, &mut active, text.len() - line_start);
                links.push(std::mem::take(&mut line_links));
                text.push('\n');
                line_start = text.len();
            } else {
                text.push(ch);
            }
            continue;
        }
        match chars.next() {
            // OSC: `ESC ]` … terminated by BEL or ST (`ESC \`).
            Some(']') => {
                let mut payload = String::new();
                while let Some(c) = chars.next() {
                    if c == '\x07' {
                        break;
                    }
                    if c == '\x1b' && chars.peek() == Some(&'\\') {
                        chars.next();
                        break;
                    }
                    payload.push(c);
                }
                if let Some(target) = osc8_target(&payload) {
                    close_link(&mut line_links, &mut active, text.len() - line_start);
                    if !target.is_empty() {
                        active = Some((text.len() - line_start, target.to_string()));
                    }
                }
            }
            // CSI: `ESC [` … terminated by a final byte in `0x40..=0x7e`.
            Some('[') => {
                for c in chars.by_ref() {
                    if ('\x40'..='\x7e').contains(&c) {
                        break;
                    }
                }
            }
            // Any other escape (or a truncated one): drop what we have.
            _ => {}
        }
    }
    close_link(&mut line_links, &mut active, text.len() - line_start);
    links.push(line_links);

    // The loop starts a fresh line after every newline, so it leaves one entry
    // too many exactly when the artwork ends with one — and an empty artwork
    // has no lines at all. `lines()` is what the caller iterates, so trim the
    // link table to match it.
    links.truncate(text.lines().count());

    MermaidArt { text, links }
}

/// End the open OSC 8 run at byte `end`, recording it if it covers anything.
fn close_link(links: &mut Vec<MermaidLink>, active: &mut Option<(usize, String)>, end: usize) {
    let Some((start, target)) = active.take() else {
        return;
    };
    if end > start {
        links.push(MermaidLink {
            start: crate::cast::u32_sat(start),
            end: crate::cast::u32_sat(end),
            target,
        });
    }
}

/// The URL of an OSC 8 payload (`8;params;url`), or `None` for any other OSC.
///
/// A closing sequence (`8;;`) yields `Some("")`, which is what tells the
/// caller to end the run rather than start one.
fn osc8_target(payload: &str) -> Option<&str> {
    let rest = payload.strip_prefix("8;")?;
    let (_params, target) = rest.split_once(';')?;
    Some(target)
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
        let narrow =
            render_text(GRAPH_LR_2, Some(40), MermaidTextBackend::Auto).expect("narrow render");

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

    // ── Terminal escape sanitisation ─────────────────────────────────────────

    /// A `click` directive must not put OSC 8 hyperlink bytes into the engine's
    /// output. An editor buffer shows them literally (`^[]8;;…`), and the URL
    /// characters would be measured as display width, corrupting the clip and
    /// `layout_width`.
    #[test]
    fn click_directives_do_not_leak_escape_sequences() {
        let src = "graph LR\n\
                   A[Alpha] --> B[Beta]\n\
                   click A href \"https://example.com/a\" \"Alpha\"\n";
        let art = render_text(src, None, MermaidTextBackend::Auto).expect("click render");
        assert!(
            !art.contains('\x1b'),
            "OSC 8 hyperlink bytes leaked into the artwork: {:?}",
            art
        );
        assert!(
            !art.contains("example.com"),
            "the URL itself leaked into the artwork: {art:?}"
        );
        assert!(art.contains("Alpha"), "the label must survive: {art:?}");
    }

    /// A linked label's byte range must cover exactly the label cells — the
    /// plugin compares a cursor byte column against it, so an off-by-one puts
    /// the link on the box border or drops its first byte.
    #[test]
    fn click_directives_carry_link_ranges() {
        let src = "graph LR\n\
                   A[Alpha] --> B[Beta]\n\
                   click A href \"https://example.com/a\" \"Alpha\"\n";
        let art = render_artwork(src, None, MermaidTextBackend::Auto).expect("click render");

        let (row, link) = art
            .links
            .iter()
            .enumerate()
            .flat_map(|(row, links)| links.iter().map(move |link| (row, link)))
            .find(|(_, link)| link.target == "https://example.com/a")
            .expect("the click target must be reported");
        let line = art.text.lines().nth(row).expect("the link's line");
        assert_eq!(
            &line[link.start as usize..link.end as usize],
            "Alpha",
            "the range must cover exactly the label, not its padding or border"
        );
    }

    /// The sanitizer must handle both OSC terminators and CSI sequences, and
    /// must leave ordinary box drawing untouched.
    #[test]
    fn strip_escape_sequences_removes_osc_and_csi() {
        let bel = strip_escape_sequences("a\x1b]8;;https://x\x07b");
        let st = strip_escape_sequences("a\x1b]8;;https://x\x1b\\b");
        let csi = strip_escape_sequences("a\x1b[31;1mb\x1b[0m");
        assert_eq!(bel.text, "ab");
        assert_eq!(st.text, "ab");
        assert_eq!(csi.text, "ab");
        assert_eq!(strip_escape_sequences("│ ┌─┐ │").text, "│ ┌─┐ │");
    }

    /// Ranges are byte offsets into the *cleaned* line, so a CJK label needs
    /// three bytes per glyph and the escape bytes must not count.
    #[test]
    fn link_ranges_are_byte_offsets_into_the_cleaned_line() {
        let art = strip_escape_sequences("│\x1b]8;;https://x\x1b\\名称\x1b]8;;\x1b\\│");
        assert_eq!(art.text, "│名称│");
        assert_eq!(
            art.links,
            vec![vec![MermaidLink {
                start: 3,
                end: 9,
                target: "https://x".to_string(),
            }]]
        );
    }

    /// Links are per line, and a run that is never closed ends with its line
    /// rather than swallowing the next one.
    #[test]
    fn link_ranges_are_per_line() {
        let art = strip_escape_sequences("a\x1b]8;;u1\x1b\\b\x1b]8;;\x1b\\c\nd\x1b]8;;u2\x1b\\e");
        assert_eq!(art.text, "abc\nde");
        assert_eq!(
            art.links,
            vec![
                vec![MermaidLink {
                    start: 1,
                    end: 2,
                    target: "u1".to_string(),
                }],
                vec![MermaidLink {
                    start: 1,
                    end: 2,
                    target: "u2".to_string(),
                }],
            ]
        );
    }
}
