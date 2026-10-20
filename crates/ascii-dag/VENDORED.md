# Vendored: ascii-dag 0.9.1

Upstream: <https://github.com/AshutoshMahala/ascii-dag>, published as
`ascii-dag` 0.9.1 on crates.io. MIT OR Apache-2.0 — both licences are kept
alongside this file.

`mermaid-text`'s Sugiyama backend is built on this crate: it feeds it the
node/edge/cluster graph and reads positions back out of the layout IR. It is
vendored for one reason — a determinism bug in 0.9.1 — and is otherwise the
published source, unmodified.

## The one change: block ordering no longer follows `HashMap` iteration

`block_partition_level` (`src/algorithms/sugiyama/subgraph.rs`) groups a
level's virtual nodes into per-subgraph blocks and then sorts those blocks by
their members' average position. The sort is *stable*, so blocks whose
averages tie keep the order the block list was built in — and 0.9.1 built that
list by iterating a `HashMap`. Under `std` a `HashMap`'s iteration order is
seeded per process, so a diagram whose blocks tie was laid out differently
from one run to the next: same source, different picture.

Upstream fixed exactly this in 0.10.1 (`40df9a2`), by recording each block
key's first appearance in a `Vec` and building the list from that. That fix is
backported here verbatim, together with upstream's regression test — an
`#[cfg(test)] mod block_order_tests` with eight average-tied blocks, which
fails 12 runs out of 12 against the unfixed code.

0.10.1 as a whole is not an option: 0.10.0 rewrote the renderer, replaced the
layout API with scene views and diagnostics, and changed rendered output for
several graph shapes. `mermaid-text` 0.57.4 is written against 0.9.1's API,
and the only part of the crate it uses is the layout IR. Taking the one
function's fix keeps every diagram that was already stable rendering byte for
byte as before.

## What pins the backport

Two tests hold the fix in place. The crate's own
`block_order_tests::tied_blocks_keep_first_appearance_order` exercises
`block_partition_level` directly. At the engine level,
`engine/tests/fixtures/diagrams.md` carries a flowchart and a `stateDiagram-v2`
whose blocks tie, and `engine/tests/corpus.rs`'s snapshot
`corpus__diagrams__rendered` pins what they render to. If the
`[patch.crates-io]` entry in the workspace `Cargo.toml` ever stops applying,
`mermaid-text` resolves to the published 0.9.1 instead: the unit test is not
compiled at all, and the corpus snapshot flaps between the two block orders
from one process to the next.

## What is not here

`assets/` (7.4 MB of images, referenced by no code) is dropped, and the
published `Cargo.toml`'s `[profile.dev]` / `[profile.release]` are removed —
Cargo ignores profiles declared by a non-root package and only warns about
them. `src/`, `examples/`, the changelog, and the README are as published.

## Updating

There is no upstream tracking. If `mermaid-text` is ever rebased onto a newer
`ascii-dag`, delete this directory and the `[patch.crates-io]` entry in the
workspace `Cargo.toml` and let the registry version back in.
